

# 函数

## 产生式

函数的定义/声明产生式如下：  
```
$funcdecl -> $storage $typeref $name "(" $params ")" ";"
$def_func -> $storage $typeref $name "(" $params ")" $block
```

## 语法分析

这里的几个全局对象，声明很类似，有的时候只靠TokenCache必须提前读取一些符号，才能辅助判断。
除了上面的函数之外，全局变量的产生式如下：
```
$def_var -> $storage $type $name ("=" $expr) ("," $name "=" $expr)* ";"
```

从上面可以看出，前面几部分都是相似的，只能根据$name之后出现的那个符号，才能判断这个全局对象是属于哪一类：
1. $name之后是"="或";"：全局变量  
2. $name之后是"("：函数声明或定义  
3. 其他符号，则是语法错误。  

2中，在解析完`$params`和")"之后，才能再次通过";"还是"{"（```$block```的起始符号）来判断是否是函数声明还是定义。  

一些出现比较晚的编程语言，为了避免C语言这种向前走N个符号才能判断是变量还是函数的情况，  
就增加了def/func/function这样专用于函数的关键字，并且将函数名提前，返回类型向后放。将重要的信息放在前面，让解析器提前分支，从而提高编译的效率。  

如果是定义的话，要做重名检查。  
在Cb语言中，不允许函数重载，所以我们直接记录函数名->函数数据结构的映射，通过函数名做检查即可。  

## 代码生成

llvm中，提供了一个用于描述函数的llvm::Value子类：llvm::Function。 

> 关于Function的介绍在这里: https://llvm.org/docs/LangRef.html#functions  
> Function的具体接口含义，文章中没有提到的部分，请参考源代码。  

llvm::Function如果携带了BasicBlock的话，那么这些BasicBlock就是这个函数的代码，  
也可以理解成一般意义上的“定义”。  

每一个函数都必须挂在一个LLVMModule下，注意：LLVMModule不会对函数做去重处理，这些逻辑需要前端完成。  
在前端未做任何处理的情况下，两个同名同参同返回值的函数，会同时存在。  

llvm中，创建Function的接口如下：
```
// llvm/include/llvm/IR/Function.h
// private:
  Function(FunctionType *Ty, LinkageTypes Linkage, unsigned AddrSpace,
           const Twine &N = "", Module *M = nullptr);
// public:
  static Function *Create(FunctionType *Ty, LinkageTypes Linkage,
                          const Twine &N = "", Module *M = nullptr); 
```

首先，可以发现，开发者有权限调用的接口是下面那个Create接口。  
而Function本身的构造函数则是private的，只能由上述的Create接口调用，这是llvm源码中常见的一种工程策略，  
主要好处是：1. 令接口更统一。2. 对调用参数进行约束，开发者不关心的参数，就不需要传入。3. 减少出错风险。  

Function的构造函数有5个参数，含义如下：
- FunctionType：这个主要指的是函数的类型，在类型的章节会讲一下。
- LinkageTypes：全局对象的链接范围。llvm::Function是一个全局对象。  
  比如，LinkageTypes::ExternalLinkage指函数是可以被外部链接的（即其他编译单元可见）
  LinkageTypes::InternalLinkage指函数只能出现在目标文件的local的符号表中，只能由本编译单元可见（类似C中的static）  
- AddrSpace：地址空间，这个主要用于IO，GPU计算等需要和内存空间做映射的场景，在我们这里不需要关心。（Create接口也没有这个参数）
- Twine N：这个参数是函数的名字。  
  Twine是llvm中提供的字符串类中的一种，我们只要知道这是一个字符串类型就行了。
- Module M：函数所属的LLVMModule

如果是函数的声明，到这里就可以了。  

如果是函数定义，那么还需要继续向下走。看一下语句块的处理。  

# 语句块

## 产生式

正常来讲，C语言的语句块产生式如下：  

```
$block -> "{" $def_var_list $stmts "}"
```

这里就限制了所有定义必须出现在语句块的头部。我们这里做了一些改进，去掉了这个限制。  
新的产生式如下：  

```
$block -> "{" ($def_var | $stmt)* "}"
```

也正是因为我们是用的自己实现的解析器，产生式变化之后，基本不需要改什么东西。  

变量定义部分先不看，首先看一下语句。  

语句包括这些形式：  

```
$stmt -> ";" / $expr ";" / $block / $if_stmt / $while_stmt / $dowhile_stmt / $for_stmt / $switch_stmt / $break_stmt / $continue_stmt / $goto_stmt / $return_stmt
```

就是基本的表达式 / 语句块 / 控制流。

本节主要关注的是基本的表达式。
不过，在看表达式的解析之前，首先要了解llvm中语句块的知识。  

## 语句块的代码生成

llvm代码中，使用结构体llvm::BasicBlock来描述一个语句块，语句块具有以下特点：

- 每个代码中实际执行的指令，都属于某一个具体的BasicBlock。  
- BasicBlock必须挂在一个llvm::Function之下。  
- 每个BasicBlock的**最后**都有一条跳转指令离开该BasicBlock。  
- 除了函数中的第一个BasicBlock，一个BasicBlock至少要有一条跳转指令作为目标。  

这里我们先不考虑语句块的嵌套，那么一个函数定义里面，就只有一个语句块。
该语句块以ret语句作为结束。  

可以使用`BasicBlock::Create`创建语句块。  
```
static BasicBlock *Create(LLVMContext &Context, const Twine &Name = "",
                            Function *Parent = nullptr,
                            BasicBlock *InsertBefore = nullptr);
```
insertBefore != nullptr的情况，主要用于对已生成的代码做修改，比如插桩等。  
我们这里都是按照源码顺序生成代码的，比较少用到insertbefore != nullptr的情况。

Parent != nullptr，表示在函数中插入该block；那么为什么还会有Parent == nullptr的情况呢？  
原因是，一些情况对应的block代码尚未生成，但是此时又必须有一个跳转指令跳转过去。这种情况就必须先创建无主的BasicBlock，之后再把该BasicBlock，插入到实际的位置。  
比如对while语句生成时，在生成循环条件的表达式之后，这时就要生成br cond的跳转指令，如果条件表达式的值为false，就要跳转到整个while之后，但是此时while的循环体还没有生成，那么就要采用这种技巧。  

之后，可以通过SetInsertBlock和GetInsertBlock接口不断调整插入指令的位置，从而完成整个语句块的代码生成。  
这里有一个坑要提示一下，就是开发者不能假定当前指令的插入位置。  
以前学习编译器的教程时，我们可能会这样处理，就是把指令的汇编语言的文本按顺序写到汇编代码中。那么，可能有一个假定，指令的生成会紧挨着之前生成的位置继续执行下去。但是这对于llvm ir的basic block是行不通的。  
按前面的说法，一个语句块会以跳转指令作为结束，那么

# 表达式

## 语法分析

表达式(Expression)这里指的是可以计算获得一个具体的值的代码。  
比如a+b, 1, "hello", 12.34, func(10, 20)等等，注意赋值类表达式也是有值的，比如a=123，这个表达式的值就是123，b=(a=456)执行之后，b的值就是456。  

这里由于还没有变量，我们只考虑常量的值。  
这里实现的常量包括字符常量，字符串常量，整形数常量，浮点数常量，nullptr。

为了支持完整的表达能力，字符支持'\123', '\x30'这种格式。  
整形数支持十进制，八进制(0开头)，十六进制(0x开头，abcde大小写均可)。  

实际上，在语法解析时，这些常量的内容就已经是确定的了。
换句话说，不考虑上下文，只根据这些常量本身，就可以知道其值。  

有人可能问这样的情况：
```
int m = 12.345; 
```
这里m的值应该是12，不是12.345。

在这里，我们是通过隐式的cast解决这类问题的，在语法分析阶段，我们仍然拿到的是12.345这个常量，
而在处理变量初始化时，再判断是否类型一致，并且隐式插入类型转换的指令。  

语法分析时，我们会将常量解析成不同的AST节点。
在这些AST中，记录了这些常量实际对应的数据内容。  

关于字符串这里要说明一下，作为语言使用者，表达换行，用的是转义字符"\n"；但是，在token中，需要记录的则是"\n"这个字符本身。
具体一点，当我们从文件中读取时，看到的是两个字符0x5c(`\`)，0x6e(`n`)；在lexer词法分析时，就必须将这里执行转义了，在token中保存的只有一个ascii字符0x0a('\n'字符)

关于运算，我们也使用优先级定义的方式来动态生成运算的AST，这样就不能通过固定的模式来描述产生式了，这里也是我们使用手写分析器的原因之一。  

## 代码生成

在llvm中，本身就支持了这些常量的表达，对应的类如下：

- 字符/整形常量：llvm::ConstantInt
- 浮点数常量：llvm::ConstantFP
- 字符串常量：llvm::GlobalString
- nullptr：llvm::ConstantPointerNull

llvm::ConstantInt支持不同bit长度的整形数，所以bool/char/int等常量，可以统一用这个类型来表示。  

llvm::IRBuilder中，提供了很多用于生成计算IR的接口，并且名字起的很形象。  

要注意，llvm::IRBuilder中，一般的二元操作数指令，比如加减乘除，浮点数和整数的操作指令是分开的，如果指令的参数llvm::Value的类型不对，比如fadd中，传入了一个llvm::constantint，可能会导致程序莫名崩溃。  

在调用IRBuilder的CreateXXX生成指令之前，必须进行完善的检查动作。   

## return语句的处理

这里专门提一下return，是因为后面会真正的尝试定义函数并执行，
只有实现了return语句，才可以拿到函数的返回值，从而检验编译的正确性。  
（当然，能看到输出，才有学下去的动力不是？）

在llvm IR中，函数的return可以由ret指令表示，这个指令可以由`IRBuilder::CreateRet`接口生成 
