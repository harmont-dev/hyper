fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_prost_build::configure()
        .build_client(false)
        .compile_protos(
            &["../../proto/hyper/agent/v1/agent.proto"],
            &["../../proto"],
        )?;
    Ok(())
}
