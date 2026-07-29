# Microsoft SQL Server image

This HammerDB 6.0 Ubuntu 24.04 image installs Microsoft ODBC Driver 18 from Microsoft's repository for AMD64 or ARM64. It preserves the custom `/usr/local/unixODBC` build, including mandatory `--enable-fastvalidate`; the complete configure command is stored in `/usr/local/unixODBC-configure.args`. The installed driver filename is discovered rather than hard-coded.
