
到这里，我们学习的内容如下：

- 可以解析基本的符号
- 可以生成AST
- 学习了函数/语句块和ret语句的代码生成
- 学习了基本运算指令的代码生成
- 学习了基本的类型

以现在的知识储备，可以先完成一个基本的程序解析器———计算器了。  
现在遇到的问题是，生成了代码，又怎么运行呢？  

# JIT介绍

一般学习C语言时，写好了程序都是要编译一下，生成一个可执行文件，再运行这个可执行文件。  
但是，现在我们还无法直接生成可执行文件，一种方式是生成llvm-ir文件，再由clang编译ir执行，这种方式固然不错，有个问题就是，现在我们的编译器属于开发状态，会经常变动，如果每测一下都要：cbc->clang->a.out三步，就太麻烦了；所以我们用另一种方式，也是教程中专门教过的，就是JIT了。  

使用JIT还有一个好处，就是方便做自动化的单元测试。  
如果对着教程执行下来，就知道JIT是可以直接运行IR的函数，也就是说，我们可以像运行自己写的代码一样，运行我们编译后的IR的函数，并且拿到结果，这样，就可以直接将测试代码传入JIT，然后判断函数结果和预期是否一致，就可以自动化测试了。  

官方教程，实现了一个KaleidoscopeJIT。不过，在LLVM中，如果不需要特殊定制的话，本身就提供了一个JIT：LLJIT。

LLVM中提供的JIT有2种架构：MCJIT和ORC，LLJIT属于ORC架构。  

> 代码路径：llvm/include/llvm/ExecutionEngine/Orc/LLJIT.h  
> JIT介绍：https://releases.llvm.org/15.0.0/docs/ORCv2.html  

# 单元测试

