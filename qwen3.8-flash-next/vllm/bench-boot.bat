@echo off
rem bench boot wrapper: one unattended boot of the mtp tier through up.sh
rem the log and the verdict land in the runtime area - bench-boot.log there,
rem not /tmp - so a distro restart does not erase the record.
set "SELF=%~dp0"
wsl -d Ubuntu -u root -- bash %SELF%_bench-boot-boot.sh
