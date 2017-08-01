$ErrorActionPreference = "Stop"

function run(){
    param($command)
    & $env:ComSpec /c ($command + ' 2>&1')
}

# consts
$luatar = 'LuaJIT-2.0.5.zip'
$luadir = 'LuaJIT-2.0.5'
$pyversion = (python -c "print(__import__('sys').version)")
if($pyversion.Contains('32 bit')){
    $arch = 'x86'
}else{
    $arch = 'x64'
}
if($pyversion.Contains('MSC v.1500')){
    # CPython 2.6, 2.7, 3.0, 3.1, 3.2
    $comntools = $env:VS90COMNTOOLS
}elseif($pyversion.Contains('MSC v.1900')){
    # CPython 3.5, 3.6
    $comntools = $env:VS140COMNTOOLS
}elseif($pyversion.Contains('MSC v.1600')){
    # Cpython 3.3, 3.4
    $comntools = $env:VS100COMNTOOLS
}else{
    throw 'Fail to detect msvc version'
}
$vcvarsall = "$comntools\..\..\VC\vcvarsall.bat"

# clean
Remove-Item -Recurse $luadir, 'build', 'lupa.egg-info', 'backup' -ErrorAction SilentlyContinue
if($args[0] -eq 'clean'){
    Exit
}elseif($args[0] -eq 'distclean'){
    Remove-Item -Recurse 'dist', $luatar -ErrorAction SilentlyContinue
    Exit
}

# print info
Write-Host ('building for ' + $pyversion) -ForegroundColor Magenta
Write-Host ('arch: ' + $arch) -ForegroundColor Magenta
Write-Host ('msvc location: ' + $comntools) -ForegroundColor Magenta

# get lua tar
if((Test-Path $luatar) -eq $false){
    Invoke-WebRequest 'http://luajit.org/download/LuaJIT-2.0.5.zip' -OutFile $luatar
}
if((Get-FileHash $luatar -Algorithm MD5).Hash -ne 'f7cf52a049d74aee4e624bdc1160b80d'.ToUpper()){
    throw 'MD5 mismatch'
}
Expand-Archive $luatar -DestinationPath .

# build lua
$origin_pwd = (Get-Location)
Set-Location "$luadir\src"
run "call `"$vcvarsall`" $arch && msvcbuild.bat"
Set-Location $origin_pwd

# build lupa
if(Test-Path 'dist'){
    Move-Item 'dist' 'backup'
}
run 'pip install -r requirements.txt'
run 'pip install wheel'
run 'python setup.py bdist_wheel'
run ('pip install ' + @(Get-ChildItem dist\*.whl)[0] + ' -U')
if(Test-Path 'backup'){
    Move-Item backup\*.whl 'dist' -ErrorAction SilentlyContinue
    Remove-Item -Recurse 'backup'
}

# test lupa
Set-Location 'lupa\tests'
run 'python __init__.py'
$testexitcode = $lastexitcode
Set-Location "..\.."
Exit $testexitcode
