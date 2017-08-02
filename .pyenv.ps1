$ErrorActionPreference = "Stop"

$safe_paths = @()
$origin_path = $env:Path
$env:Path.Split(';') | ForEach-Object{
    $env:Path = $_
    $issafe = $true
    try{
        Get-Command 'python' | Out-Null
        $issafe = $false
    }catch [System.Management.Automation.CommandNotFoundException]{}
    try{
        Get-Command 'pip' | Out-Null
        $issafe = $false
    }catch [System.Management.Automation.CommandNotFoundException]{}
    if($issafe){
        $safe_paths += $_
    }
}
$env:Path = ((@($args[0], ($args[0] + '\Scripts')) + $safe_paths) -join ';')
& $args[1]
$exitcode = $LASTEXITCODE
$env:Path = $origin_path
Exit $exitcode
