
CFG类被设计用来表达一个语句的代码级的控制流图。CFG比较典型应用与函数体的构建上（一般作为CompoundStmt的实例），当然也会用来表达一些Stmt子类的控制流，比如简单的表达式。控制流图在处理在对函数进行流敏感或者路径敏感的程序分析时可用。  

## 基本语句块
结构上，CFG是实例是一些基本语句块的集合。每个语句块都是一个CFGBlock类的实例，CFGBlock只简单包含了排好序的Stmt*序列（每个Stmt*代表AST中的一个语句）。块中语句的顺序代表语句间控制流的无条件的流转关系（就是按照代码顺序一条接一条执行）。条件控制流通过语句间的边表达。可以通过CFGBlock::*iterator来遍历CFGBlock中的语句。    
一个CFG对象包含其表达的控制流图，以及CFGBlock实例集合。CFG内部的每个CFGBlock对象被在CFG内部唯一编号（通过CFGBlock::getBlockID()）。目前实现中，这个编号根据语句块创建的顺序指定，但是除了编号独立和范围[0..N-1]（N是CFG中CFGBLock对象的个数）之外，不能假定其编号的机制。  

## 入口/出口语句块
每个CFG包含两个特殊的块：入口块（通过CFG::getEntry()）访问，没有边指向该块；以及出口块，（通过 CFG::getExit()访问），没有边从该块指出。这两个块不包含语句，其作用是指明一段实体代码的入口和出口，比如函数体。这些空块的存在简化了从CFG顶层进行分析的实现。  
## 条件控制流
条件控制流（比如if语句和循环）通过CFGBlock之间的边来表达。因为不同的C系语言的构建也会引发控制流，每个CFGBlock也记录了额外的Stmt*来指明该块的结束符。一个结束符就是导致控制流的语句，可以用来确定块之间的控制流的流转方式。比如，if-statement这类语句，其结束符就是表达指定分支的IfStmt。  
为了说明这一情况，考虑如下代码：
```c
int foo(int x) {
  x = x + 1;
  if (x > 2)
    x++;
  else {
    x += 2;
    x *= 2;
  }

  return x;
}
```
在此代码片段上调用语法语义分析之后，有一个单独的Stmt*引用foo的实体的AST。调用一个类的静态方法一次，就可以创建表达该函数体的控制流图的CFG实例：
```c
Stmt *FooBody = ...
std::unique_ptr<CFG> FooCFG = CFG::buildCFG(FooBody);
```
除了提供遍历CFGBlock实例的接口之外，CFG类还提供了方法来帮助调试和观测CFG。比如，CFG::dump()会向标准错误dump一个格式美观的CFG版本。这个在使用类似gdb这样调试器时很有用，比如，这个是FooCFG->dump()的输出：
```c
[ B5 (ENTRY) ]
   Predecessors (0):
   Successors (1): B4

[ B4 ]
   1: x = x + 1
   2: (x > 2)
   T: if [B4.2]
   Predecessors (1): B5
   Successors (2): B3 B2

[ B3 ]
   1: x++
   Predecessors (1): B4
   Successors (1): B1

[ B2 ]
   1: x += 2
   2: x *= 2
   Predecessors (1): B4
   Successors (1): B1

[ B1 ]
   1: return x;
   Predecessors (2): B2 B3
   Successors (1): B0

[ B0 (EXIT) ]
   Predecessors (1): B1
   Successors (0):
```
每个输出都会展示其前向块（控制流的指出块是该块）和后向块（该块的控制流的指出块）个数。也可以很明确的看到在输出的开始和结束部分，分别打印了入口块和出口块。入口块（B5）的前向块的个数是0；出口块（B0）的后向块个数是0。  
看一下B4这个块。指出控制流表达了只由这个单独的if语句导致的分支。看一下这个块的第二个语句：x>2，以及结束符，就是if[B4,2]。第二个语句表达这个if语句对应条件的计算，一般在控制流开始分支之前发生。B4的CFGBlock中，第二个语句的Stmt*指针指向(x>2)对应的实际表达式的AST。除了在Stmt的子类之外指向C语句之外，这些指向Expr类的子类的指针会在块的语句中出现。  
B4的结束符是指向AST中IfStmt语句的指针。输出if[B4,2]的原因是，if-statement的条件表达式需要在块中有实际的位置，那么这个结束符就可以指向B4的第二个语句块，即B4.2。通过这种方式可以将控制流中的条件（也包括循环和switch语句）挂载实际的基本块中。  