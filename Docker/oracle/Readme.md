# Oracle image

This HammerDB 6.0 Ubuntu 24.04 image selects Oracle Instant Client Basic
23.8.0.25.04 for Linux x86-64 or Linux ARM64 from Oracle's official download
host. The paired archive names are
`instantclient-basic-linux.x64-23.8.0.25.04.zip` and
`instantclient-basic-linux.arm64-23.8.0.25.04.zip`. Required SHA-256 inputs
protect each archive, and the build's fail-on-error download verifies that the
selected asset remains available. The stable `/opt/oracle/instantclient` path,
architecture-correct Ubuntu `libaio`, `file`, `ldd`, linker, and HammerDB
extension checks avoid x86-only assumptions.
