# Package

version       = "0.1.0"
author        = "Luyten-Orion"
description   = "An MC server implementation written in Nim!"
license       = "MIT"
srcDir        = "src"
bin           = @["kimberlite"]


# Dependencies

requires "nim >= 2.0.8"
requires "https://github.com/luyten-orion/nim-sys#06ba7f8"
requires "cps ^= 0.11.1"
requires "https://github.com/nimberite-development/modernnet >= 3.2.2"