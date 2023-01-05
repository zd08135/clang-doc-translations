
用于快速构建release分支。  

注，windows使用powershell执行，执行前要打开脚本权限。  

```
Get-ExecutionPolicy
Set-ExecutionPolicy RemoteSigned
Get-ExecutionPolicy
```

Get-ExecutionPolicy输出为`RemoteSigned`时即可。  
```
PS D:\Projects\CCpp\clang-doc-translations> Get-ExecutionPolicy
RemoteSigned
```


