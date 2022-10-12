
# 基本说明

## 源码地址

参考llvm github:    
https://github.com/llvm/llvm-project.git  
https://gitee.com/mirrors/LLVM.git  （github地址的国内镜像，每日同步）  

## 版本选择

基于clang11版本文档翻译  
https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html  

选择11.0版本的代码，具体版本如下：
```
commit 1fdec59bffc11ae37eb51a1b9869f0696bfd5312 (HEAD, tag: llvmorg-11.1.0-rc3, tag: llvmorg-11.1.0, origin/release/11.x)
Author: Andi-Bogdan Postelnicu <abpostelnicu@me.com>
Date:   Wed Feb 3 17:38:49 2021 +0000

    [lldb] Fix fallout caused by D89156 on 11.0.1 for MacOS
    
    Fix fallout caused by D89156 on 11.0.1 for MacOS
    
    Differential Revision: https://reviews.llvm.org/D95683
```

TODO: 未来可能会按照clang版本形式，将本文档也划分成不同版本

## 平台

本文的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）
