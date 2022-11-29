
LLVM支持库libSupport提供了一些底层库和[数据结构](https://releases.llvm.org/11.0.0/docs/ProgrammersManual.html)，包括命令行处理、不同的container以及用于文件系统访问的系统抽象层。  

> 命令行处理：llvm/Support/CommandLine.h下的一些辅助函数，可用来实现命令行参数解析
> container：llvm提供的一些容器，实现基本的string, vector, set, map等操作，比如DenseMap, FoldingSet等
> 文件系统抽象层：llvm/Support/raw_ostream中的一些文件类util
> 以上几个模块在实现基于LLVM的编译器时都很有用。

---------------------    

[原文](https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html#llvm-support-library)
