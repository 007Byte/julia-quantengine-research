# ── Vault Tests ───────────────────────────────────────────────

using QuantEngine: _derive_key, _xor_crypt

@testset "EnvVault" begin
    vault = EnvVault()

    # PATH always exists in ENV
    @test !isempty(get_secret(vault, "PATH"))
    @test has_secret(vault, "PATH")

    # Non-existent key returns default
    @test get_secret(vault, "QE_NONEXISTENT_12345") == ""
    @test get_secret(vault, "QE_NONEXISTENT_12345"; default="fallback") == "fallback"
    @test has_secret(vault, "QE_NONEXISTENT_12345") == false
end

@testset "EnvVault list_secrets" begin
    vault = EnvVault()
    keys = list_secrets(vault)
    @test keys isa Vector{String}
    # All returned keys should start with QE_ or POLYMARKET_
    for k in keys
        @test startswith(k, "QE_") || startswith(k, "POLYMARKET_")
    end
end

@testset "EncryptedFileVault requires master key" begin
    dir = mktempdir()
    @test_throws ErrorException EncryptedFileVault(
        joinpath(dir, "vault.enc");
        master_key_env="NONEXISTENT_VAULT_KEY_12345"
    )
end

@testset "EncryptedFileVault roundtrip" begin
    dir = mktempdir()
    filepath = joinpath(dir, "vault.enc")

    withenv("QE_TEST_VAULT_KEY" => "my_secret_master_password_123") do
        # Create vault and store secrets
        vault = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")

        set_secret!(vault, "QE_ALPACA_API_KEY", "AKXXXXXXXXXX")
        set_secret!(vault, "QE_ALPACA_SECRET_KEY", "secret_value_here")
        set_secret!(vault, "POLYMARKET_API_KEY", "poly_key_123")

        # Verify in-memory
        @test get_secret(vault, "QE_ALPACA_API_KEY") == "AKXXXXXXXXXX"
        @test get_secret(vault, "QE_ALPACA_SECRET_KEY") == "secret_value_here"
        @test has_secret(vault, "QE_ALPACA_API_KEY")
        @test !has_secret(vault, "QE_NONEXISTENT")

        # Verify file exists and is encrypted
        @test isfile(filepath)
        raw = read(filepath)
        @test !occursin("AKXXXXXXXXXX", String(raw))  # not plaintext

        # Create a new vault from the same file — should decrypt
        vault2 = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")
        @test get_secret(vault2, "QE_ALPACA_API_KEY") == "AKXXXXXXXXXX"
        @test get_secret(vault2, "QE_ALPACA_SECRET_KEY") == "secret_value_here"
        @test get_secret(vault2, "POLYMARKET_API_KEY") == "poly_key_123"
    end
end

@testset "EncryptedFileVault wrong key" begin
    dir = mktempdir()
    filepath = joinpath(dir, "vault.enc")

    # Write with one key
    withenv("QE_TEST_VAULT_KEY" => "correct_password") do
        vault = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")
        set_secret!(vault, "TEST_KEY", "test_value")
    end

    # Try to read with wrong key — should not crash, just warn
    withenv("QE_TEST_VAULT_KEY" => "wrong_password") do
        vault2 = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")
        # Decryption with wrong key produces garbage, not the original value
        result = get_secret(vault2, "TEST_KEY")
        @test result != "test_value" || result == ""  # either empty or garbled
    end
end

@testset "EncryptedFileVault delete_secret!" begin
    dir = mktempdir()
    filepath = joinpath(dir, "vault.enc")

    withenv("QE_TEST_VAULT_KEY" => "test_pass") do
        vault = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")
        set_secret!(vault, "KEY1", "val1")
        set_secret!(vault, "KEY2", "val2")

        @test has_secret(vault, "KEY1")
        delete_secret!(vault, "KEY1")
        @test !has_secret(vault, "KEY1")
        @test has_secret(vault, "KEY2")
    end
end

@testset "EncryptedFileVault list_secrets" begin
    dir = mktempdir()
    filepath = joinpath(dir, "vault.enc")

    withenv("QE_TEST_VAULT_KEY" => "test_pass") do
        vault = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")
        set_secret!(vault, "A", "1")
        set_secret!(vault, "B", "2")
        set_secret!(vault, "C", "3")

        keys = list_secrets(vault)
        @test length(keys) == 3
        @test "A" in keys
        @test "B" in keys
        @test "C" in keys
    end
end

@testset "_xor_crypt roundtrip" begin
    key = _derive_key("test_password")
    @test length(key) == 32

    plaintext = Vector{UInt8}("Hello, World! This is a test.")
    ciphertext = _xor_crypt(plaintext, key)

    @test ciphertext != plaintext  # should be different
    @test length(ciphertext) == length(plaintext)

    # Decrypt
    decrypted = _xor_crypt(ciphertext, key)
    @test decrypted == plaintext
end

@testset "create_vault default is EnvVault" begin
    vault = create_vault()
    @test vault isa EnvVault
end

@testset "EncryptedFileVault file permissions" begin
    dir = mktempdir()
    filepath = joinpath(dir, "vault.enc")

    withenv("QE_TEST_VAULT_KEY" => "test_pass") do
        vault = EncryptedFileVault(filepath; master_key_env="QE_TEST_VAULT_KEY")
        set_secret!(vault, "KEY", "VALUE")

        # File should exist with restricted permissions
        @test isfile(filepath)
        mode = filemode(filepath) & 0o777
        @test mode == 0o600  # owner read/write only
    end
end
