
## 源码地址

参考llvm github:  
<https://github.com/llvm/llvm-project.git>  
<https://gitee.com/mirrors/LLVM.git>  （github地址的国内镜像，每日同步）  

## 版本选择

基于clang11版本文档翻译  
<https://releases.llvm.org/15.0.0/tools/clang/docs/InternalsManual.html>

选择11.0版本的代码，具体版本如下：

```
commit 1fdec59bffc11ae37eb51a1b9869f0696bfd5312 (HEAD, tag: llvmorg-11.1.0-rc3, tag: llvmorg-11.1.0, origin/release/11.x)
Author: Andi-Bogdan Postelnicu <abpostelnicu@me.com>
Date:   Wed Feb 3 17:38:49 2021 +0000

    [lldb] Fix fallout caused by D89156 on 11.0.1 for MacOS

    Fix fallout caused by D89156 on 11.0.1 for MacOS

    Differential Revision: https://reviews.llvm.org/D95683
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
