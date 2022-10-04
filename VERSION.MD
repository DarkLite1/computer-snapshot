# Version 1.1
- Add support relative paths to `Start-Script.ps1`

# Version 1.0
- Add support for installing software executables in other locations
  Update `Software.json`:
    > rename `ExecutableName` to `ExecutablePath`
    > use `.\Packages\foobar.exe` instead of `foobar.exe`