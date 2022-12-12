

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



