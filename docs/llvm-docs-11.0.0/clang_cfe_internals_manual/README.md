
## 源码地址

参考llvm github:  
<https://github.com/llvm/llvm-project.git>  
<https://gitee.com/mirrors/LLVM.git>  （github地址的国内镜像，每日同步）  

## 版本选择

基于clang15版本文档翻译  
<https://releases.llvm.org/15.0.0/tools/clang/docs/InternalsManual.html>

选择15.0版本的代码，具体版本如下：

```
commit 5c68a1cb123161b54b72ce90e7975d95a8eaf2a4 (HEAD, tag: llvmorg-15.0.4, origin/release/15.x, release/15.x)
Author: Matt Arsenault <Matthew.Arsenault@amd.com>
Date:   Mon Sep 26 23:07:49 2022 -0400

    AMDGPU: Make various vector undefs legal
    
    Surprisingly these were getting legalized to something
    zero initialized.
    
    This fixes an infinite loop when combining some vector types.
    Also fixes zero initializing some undef values.
    
    SimplifyDemandedVectorElts / SimplifyDemandedBits are not checking
    for the legality of the output undefs they are replacing unused
    operations with. This resulted in turning vectors into undefs
    that were later re-legalized back into zero vectors.
```
## 平台

本文的中的附加内容需要实际开发运行的部分，相关的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）  
推荐使用VSCode作为IDE开发：<https://code.visualstudio.com/>

## 备注

本文中的引用是本人自己添加的，不是原文的翻译。
> 这段文字是我添加的内容
> ```
> 这段代码是我添加的内容
> ```

TODO: **未来可能会按照clang版本形式，将本文档也划分成不同版本**  
FIXME: **文中出现的其他链接，部分会链接到llvm docs的原始网站，如果未来对应文档也有翻译的话，会同步修正为本书内部的链接。**
