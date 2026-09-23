@echo off
rem pickpair.bat - the tickbox-style GPU picker, shared by the install bats.
rem
rem   call pickpair.bat
rem
rem Prints the box's cards as a numbered list, takes TWO picks - tensor-
rem parallel-2 needs exactly two distinct cards, and a single-card install
rem is not a supported configuration, so the name install-dual is the
rem contract - then confirms before returning. Sets PAIR=a,b in the caller
rem on confirm, or PAIR_KEEP=1 when the caller keeps its standing pair.
rem The card list comes from nvidia-smi -L, the same source the boot's
rem card gate queries, so every offered index is real.
rem
rem EOF note: set /p leaves its variable unchanged on end-of-input, so every
rem re-ask loop clears PP_IN first - an exhausted pipe re-asks as empty and
rem exits the loop instead of spinning on the stale value forever.

:pickpair
set "PAIR_KEEP="
set "PP_C1="
set "PP_C2="
setlocal EnableDelayedExpansion

echo.
echo  this box reports:
nvidia-smi -L
if errorlevel 1 (
    echo  nvidia-smi failed - no card list to offer. Set DEVICE_PAIR by
    echo  hand in the tier .envs if you know the indexes.
    endlocal & set "PAIR_KEEP=1"
    exit /b 1
)

:pickpair_first
echo.
set "PP_IN="
set /p PP_IN="  pick the FIRST card [index, enter=keep the standing pair]: "
if not defined PP_IN goto :pickpair_keep
call :pickpair_valid "!PP_IN!" || goto :pickpair_first
set "PP_C1=%PP_IN%"
echo   picked card %PP_C1% - now the second, a different one

:pickpair_second
echo.
set "PP_IN="
set /p PP_IN="  pick the SECOND card [index, enter=start over]: "
if not defined PP_IN goto :pickpair
call :pickpair_valid "!PP_IN!" || goto :pickpair_second
if "%PP_IN%"=="%PP_C1%" (
    echo   card %PP_IN% is already picked - pick a different one
    goto :pickpair_second
)
set "PP_C2=%PP_IN%"
echo.
echo   selected pair: %PP_C1%,%PP_C2%
set "PP_OK="
set /p PP_OK="  [enter] write this pair   [n] start over: "
if /i "!PP_OK:~0,1!"=="n" goto :pickpair
endlocal & set "PAIR=%PP_C1%,%PP_C2%"
exit /b 0

:pickpair_keep
endlocal & set "PAIR_KEEP=1"
exit /b 0

rem pickpair_valid VALUE - a bare card index, a number, no separators.
rem The list above came from nvidia-smi itself, so a number is enough.
:pickpair_valid
set "PP_V=%~1"
if not defined PP_V (
    echo   empty - pick an index from the list above
    exit /b 1
)
set "PP_NOTNUM="
for /f "delims=0123456789" %%Z in ("%PP_V%") do set "PP_NOTNUM=1"
if defined PP_NOTNUM (
    echo   that is not a card index - pick a number from the list
    exit /b 1
)
exit /b 0
