# HammerDB 6.0 base image

The base image uses Ubuntu 24.04 and downloads, verifies, and extracts the published HammerDB 6.0 archive for AMD64 or ARM64. It does not compile HammerDB. Supply the two published archive SHA-256 build arguments; `/home/HammerDB-6.0` is exposed through stable path `/home/hammerdb`.
