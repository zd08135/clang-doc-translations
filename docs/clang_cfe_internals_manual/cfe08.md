这个库包含了一个递归下降的语法分析器，从预处理器中获取符号并通知分析流程的客户端。
历史上，分析器以前会调用一个抽象的Action接口，其定义了分析事件的一些virtual方法，比如ActOnBinOp。Clang加入C++支持之后，分析器就不再支持通用的Action客户端，而是只与Sema Library交互。不过，分析器仍然访问AST对象，但只能通过不明确的ExprResult和StmtResult类型访问。只有Sema才能通过这些wrapper来看到AST节点的实际内容。

---------------------    

[原文](https://releases.llvm.org/15.0.0/tools/clang/docs/InternalsManual.html#introduction)