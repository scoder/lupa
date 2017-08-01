$ErrorActionPreference = "Stop"

# consts
$luatar = 'LuaJIT-2.0.5.zip'
$luadir = 'LuaJIT-2.0.5'
$pyversion = (python -c "print(__import__('sys').version)")
if($pyversion.Contains('32 bit')){
    $arch = 'x86'
}else{
    $arch = 'x64'
}
$vcvarsall = (Join-Path $env:VS140COMNTOOLS '..' '..' 'VC' 'vcvarsall.bat')

# clean
Remove-Item -Recurse $luadir, 'build', 'lupa.egg-info', 'backup' -ErrorAction SilentlyContinue
if($args[0] -eq 'clean'){
    Exit
}elseif($args[0] -eq 'distclean'){
    Remove-Item -Recurse 'dist', $luatar -ErrorAction SilentlyContinue
    Exit
}

# print info
Write-Host ('building for ' + (python --version) + ' ' + $arch) -ForegroundColor Magenta

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
Set-Location (Join-Path $luadir 'src')
& $env:ComSpec /c "call `"$vcvarsall`" $arch && msvcbuild.bat"
Set-Location $origin_pwd

# build lupa
if(Test-Path 'dist'){
    Move-Item 'dist' 'backup'
}
pip install -r requirements.txt
pip install wheel
python setup.py bdist_wheel
pip install @(Get-ChildItem dist\*.whl)[0] -U
if(Test-Path 'backup'){
    Move-Item backup\*.whl 'dist' -ErrorAction SilentlyContinue
    Remove-Item -Recurse 'backup'
}

# test lupa
python setup.py test
Exit $lastexitcode
