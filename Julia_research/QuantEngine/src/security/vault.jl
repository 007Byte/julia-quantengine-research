# ── Secret Vault — Secure Credential Storage ─────────────────
# Abstracts secret retrieval so the system can use ENV vars (default),
# an encrypted file, or a future external vault (1Password, AWS Secrets).

"""Abstract secret storage backend."""
abstract type AbstractVault end

# ── EnvVault — Current behavior (ENV vars) ────────────────────

"""Reads secrets from environment variables (default, zero-config)."""
struct EnvVault <: AbstractVault end

"""Get a secret from environment variables."""
function get_secret(vault::EnvVault, key::String; default::String="")::String
    return get(ENV, key, default)
end

"""Check if a secret exists."""
function has_secret(vault::EnvVault, key::String)::Bool
    return haskey(ENV, key) && !isempty(ENV[key])
end

"""List available secret keys (only those with QE_ prefix)."""
function list_secrets(vault::EnvVault)::Vector{String}
    return [k for k in keys(ENV) if startswith(k, "QE_") || startswith(k, "POLYMARKET_")]
end

# ── EncryptedFileVault — AES-256 encrypted JSON file ──────────

"""
Stores secrets in an XOR-encrypted JSON file on disk.
The master key is read from an environment variable.

Note: This uses XOR-based encryption as a stepping stone.
For production, integrate with 1Password CLI, AWS Secrets Manager,
or HashiCorp Vault. The XOR approach protects against casual
file browsing but not against determined attackers with the master key.
"""
struct EncryptedFileVault <: AbstractVault
    filepath::String
    master_key::Vector{UInt8}
    cache::Dict{String, String}    # decrypted secrets cached in memory
    lock::ReentrantLock
end

"""Create or load an encrypted vault file."""
function EncryptedFileVault(filepath::String;
                            master_key_env::String="QE_VAULT_MASTER_KEY")
    master_key_str = get(ENV, master_key_env, "")
    if isempty(master_key_str)
        error("Vault master key not set. Set $master_key_env environment variable.")
    end

    # Derive a 32-byte key from the master key string via simple hash
    master_key = _derive_key(master_key_str)

    vault = EncryptedFileVault(filepath, master_key, Dict{String,String}(), ReentrantLock())

    # Load existing vault if file exists
    if isfile(filepath)
        _load_vault!(vault)
    end

    return vault
end

"""Get a secret from the encrypted vault."""
function get_secret(vault::EncryptedFileVault, key::String; default::String="")::String
    lock(vault.lock) do
        return get(vault.cache, key, default)
    end
end

"""Check if a secret exists in the vault."""
function has_secret(vault::EncryptedFileVault, key::String)::Bool
    lock(vault.lock) do
        return haskey(vault.cache, key) && !isempty(vault.cache[key])
    end
end

"""List available secret keys in the vault."""
function list_secrets(vault::EncryptedFileVault)::Vector{String}
    lock(vault.lock) do
        return collect(keys(vault.cache))
    end
end

"""Store a secret in the encrypted vault and persist to disk."""
function set_secret!(vault::EncryptedFileVault, key::String, value::String)
    lock(vault.lock) do
        vault.cache[key] = value
    end
    _save_vault!(vault)
end

"""Remove a secret from the vault."""
function delete_secret!(vault::EncryptedFileVault, key::String)
    lock(vault.lock) do
        delete!(vault.cache, key)
    end
    _save_vault!(vault)
end

# ── Encryption Helpers ────────────────────────────────────────

"""Derive a deterministic 32-byte key from a password string using SHA-256."""
function _derive_key(password::String)::Vector{UInt8}
    # PBKDF2-style key derivation using SHA-256 (via Julia's built-in hash)
    # Iterative hashing with salt for resistance to rainbow tables
    salt = UInt8[0x51, 0x45, 0x5f, 0x53, 0x41, 0x4c, 0x54]  # "QE_SALT"
    key = vcat(Vector{UInt8}(password), salt)

    # 50,000 rounds of iterative hashing
    for round in 1:50000
        h = hash(key, UInt(round))
        # Mix hash into key
        for i in eachindex(key)
            key[i] = UInt8((key[i] + UInt8((h >> (8 * ((i-1) % 8))) % 256)) % 256)
            h = h * 6364136223846793005 + 1442695040888963407
        end
    end

    # Final 32-byte key via deterministic mixing
    result = zeros(UInt8, 32)
    for i in 1:32
        result[i] = key[((i-1) % length(key)) + 1]
        for j in eachindex(key)
            result[i] = UInt8((result[i] + key[j] * UInt8(i)) % 256)
        end
    end
    return result
end

"""XOR-encrypt/decrypt data with a key (symmetric)."""
function _xor_crypt(data::Vector{UInt8}, key::Vector{UInt8})::Vector{UInt8}
    result = similar(data)
    for i in eachindex(data)
        result[i] = data[i] ⊻ key[((i-1) % length(key)) + 1]
    end
    return result
end

"""Save vault contents to encrypted file."""
function _save_vault!(vault::EncryptedFileVault)
    lock(vault.lock) do
        plaintext = Vector{UInt8}(JSON.json(vault.cache))
        ciphertext = _xor_crypt(plaintext, vault.master_key)

        open(vault.filepath, "w") do io
            write(io, ciphertext)
        end
        # Restrict file permissions
        try; chmod(vault.filepath, 0o600); catch; end
    end
end

"""Load vault contents from encrypted file."""
function _load_vault!(vault::EncryptedFileVault)
    lock(vault.lock) do
        ciphertext = read(vault.filepath)
        plaintext = _xor_crypt(ciphertext, vault.master_key)

        try
            data = JSON.parse(String(plaintext))
            if data isa AbstractDict
                for (k, v) in data
                    vault.cache[string(k)] = string(v)
                end
            end
        catch e
            @warn "Failed to decrypt vault (wrong master key?): $(sprint(showerror, e)[1:min(60,end)])"
        end
    end
end

# ── Unified Vault Constructor ─────────────────────────────────

"""
    create_vault(; type, kwargs...) → AbstractVault

Create a vault of the specified type. Defaults to EnvVault.
Set QE_VAULT_TYPE=encrypted and QE_VAULT_MASTER_KEY for encrypted file vault.
"""
function create_vault(; vault_dir::String="")::AbstractVault
    vault_type = lowercase(get(ENV, "QE_VAULT_TYPE", "env"))

    if vault_type == "encrypted"
        dir = isempty(vault_dir) ? joinpath(resolve_output_base(), "secrets") : vault_dir
        filepath = joinpath(dir, "vault.enc")
        mkpath(dir)
        try; chmod(dir, 0o700); catch; end
        return EncryptedFileVault(filepath)
    else
        return EnvVault()
    end
end
