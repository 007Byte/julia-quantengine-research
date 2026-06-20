#!/usr/bin/env julia
# Test the bridge types and dispatch without ZMQ

push!(LOAD_PATH, joinpath(@__DIR__, ".."))

include("bridge_types.jl")
using .BridgeTypes
using JSON
using Test

@testset "Bridge Types" begin
    @testset "HeartbeatResponse serialization" begin
        resp = BridgeTypes.HeartbeatResponse("ok", 100.0, 34)
        json_str = JSON.json(Dict(
            "type" => "heartbeat_response",
            "status" => resp.status,
            "uptime_seconds" => resp.uptime_seconds,
            "models_loaded" => resp.models_loaded,
        ))
        parsed = JSON.parse(json_str)
        @test parsed["status"] == "ok"
        @test parsed["uptime_seconds"] == 100.0
        @test parsed["models_loaded"] == 34
    end

    @testset "Request parsing" begin
        msg = JSON.json(Dict(
            "type" => "heartbeat",
        ))
        req_type, data = BridgeTypes.parse_request(msg)
        @test req_type == "heartbeat"

        msg2 = JSON.json(Dict(
            "type" => "features",
            "instrument_id" => "test-123",
            "prices" => [100.0, 101.0, 102.0],
        ))
        req_type2, data2 = BridgeTypes.parse_request(msg2)
        @test req_type2 == "features"
        @test data2["instrument_id"] == "test-123"
        @test length(data2["prices"]) == 3
    end

    @testset "ErrorResponse" begin
        err = BridgeTypes.ErrorResponse("test error", "TEST_CODE", "details")
        @test err.error == "test error"
        @test err.code == "TEST_CODE"
    end
end

println("\nAll bridge type tests passed!")
