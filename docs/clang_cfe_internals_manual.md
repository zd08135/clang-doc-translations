
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

TODO: **未来可能会按照clang版本形式，将本文档也划分成不同版本**

## 平台

本文的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）

# 正文

## 介绍
本文档描述了clang前端中，一些重要API以及内部设计，旨在让读者可以既可以掌握一些高层次的信息，也可以了解背后的一些设计思路。本文的更针对探索clang内部原理的读者，而不是一般的使用者。下面的描述根据不同的库进行组织，但是并不会描述客户端如何使用它们。
## LLVM支持库
LLVM支持库libSupport提供了一些底层库和数据结构，包括命令行处理、不同的container以及用于文件系统访问的系统抽象层。
## Clang的基础库
这一部分库的名字可能要起得更好一点。这些“基础”库包括：追踪、操作源码buffer和包含的位置信息、诊断、符号、目标平台抽象、以及语言子集的偏基础类的util逻辑。  
部分架构只针对C语言生效（比如TargetInfo），其他部分（比如SourceLocation, SourceManager, Diagnostics, FileManager）可以用于非C的其他语言。可能未来会引入一个新的库、把这些通用的类移走、或者引入新的方案
下面会根据依赖关系，按顺序描述基础库的各个类。