$BCount = Invoke-Command -ScriptBlock {(netstat -anoq | ? {($_ -match 'Bound')}).Count}
Out-file -filepath C:\test\log.txt -Append -Encoding ascii -InputObject "$Bcount bound ports at $(Get-TimeStamp)"


function Get-TimeStamp {
    
    return "[{0:HH:mm:ss}]" -f (Get-Date)}