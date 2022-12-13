
# 基本处理

在llvm中，本身提供了比较完善的类型支持。但是，这里的实现中，并没有在类型AST中，直接引用llvm中定义的类型，而是在编译前端自身维护了一套类型系统，这和clang的实现方式一致。这么做的原因如下：

- opaque ptr问题。
  
  llvm在定义IR时，针对指针类型的变量，老版本中会显式指定指针指向的类型。比如这样：
  ```
    define i32 @test(i32* %p) {
      store i32 0, i32* %p
      %bc = bitcast i32* %p to i64*
      %v = load i64, i64* %bc
      ret i64 %v
    }
  ```
  但是后来，llvm项目组发现，使用显式类型的指针并没有多少带来多少收益。反而会因为指针类型的不一致会导致很多不必要的转换操作（上面的示例中，将一个i32的值转成i64，还要走一遍指针的类型转换），而且这个指针间的转换太不直观，容易忽略从而导致出现BUG，并且也不好支持优化...
  
  总而言之，在未来版本的LLVM中，IR会逐步使用无类型指针（opaque ptr）替代显式类型的指针。  
  在目前使用的15版本，opaque ptr是默认启用的，显式类型指针仍然支持，但是处于不维护状态了。  
  
  也就是说，现在从llvm后端拿到的指针类型，是无法记录指针指向的类型的，这样对于前端来讲是不可接受的。出于这样的考虑，我们只能在前端维护指针的这些信息。  
  
> 关于opaque ptr更多信息：https://releases.llvm.org/15.0.0/docs/OpaquePointers.html  

- 对const和volatile的支持  
  现在并未支持const类型，但是不支持的主要原因是初始化列表的解析不好解决，并非无法支持const的限制修改能力。为了支持const的能力，这里需要在编译前端记录这样的信息，在尝试修改时抛出错误。而llvm后端是无法记录这样的信息的。这里也只能在前端做记录。  

- 可扩展性  
  如果需要针对类型增加更多的特性，直接去改llvm是不现实的，所以也只能通过前端维护类型信息，后续的迭代基于前端自己的数据结构进行。  

# 类型支持

这里支持的类型包括：

基本类型：
bool：长度1的整形
(unsigned) char：长度8的整形
(unsigned) short：长度16的整形
(unsigned) int: 长度32的整形，unsigned不带后缀时也是此类型
(unsigned) long: 长度64整形

float：单精度浮点数
double：双精度浮点数

void：只能用于函数（不支持参数使用void）

指针类型
数组类型
结构体类型
函数类型

# 实现描述

llvm中，描述类型的基类是llvm::Type。代码见：llvm/include/llvm/IR/Type.h  
clang中，描述类型的基类是clang::Type。代码见：clang/include/clang/AST/Type.h  

这里采用了和clang/llvm类似的类型定义方式。  

- 前端定义一个TypeContext，用于记录类型信息。该TypeContext在一个编译单元的编译过程中全局唯一。类型的实例全部保存在TypeContext中。  
- 在TypeContext中，隐藏类型的构造函数，统一使用类的Create/Get接口创建之。主要是尽量让相同的类型使用同一个变量。这样既省空间，也方便类型一致的判断。  
- 类型包括Type和QualInfo两部分，QualInfo就是用于保存限定符信息，比如const/volatile
- typedef类型别名，只要记录直接用string->Type*即可解决。
- 基本/指针/数组/结构体类型各自有一个类型ID，该类型ID用于判断类型是否是基本/指针/数组/结构体类型。使用这类ID可以避免判断指针具体类型时的RTTI动态检查，提高效率。  

这里为了能完成基本的程序编写，我们先只考虑基本类型和函数类型。  

在本书的代码中，也定义了类型的基类Type，代码在type.h
每个类都实现了一个toLLVMType的接口，实现由我们的Type到llvm::Type的转换。  


## 基本类型

TypeContext中预定义了上面提到的若干个基本类型。  
get时直接返回即可。  

基本类型和llvm类型的对应关系：  

- bool/char/int.. -> llvm::IntegerType
  这一部分类型可以通过llvm::Type的接口直接获取对应的类型实例。  
  
- float/double -> llvm::GetFloatType/GetDoubleType

- void -> llvm::getVoidTy
 
## 函数类型 
  
函数类型包括返回值类型、参数个数和各参数的类型。  

这里用到了类型的嵌套，嵌套时，子类型成员用的是QualType(QualInfo + Type*)，
而不是直接用Type*，这个原因是为了支持函数/返回值的const能力。  
这也和clang的实现方式类似，  

如果看clang的代码的话，clang中使用了一些特殊的技巧来优化内存占用，
我们目前还不需要这一点，单纯用unsigned代表qualinfo, 用指针（在64位下长度64）代表Type*即可。  

从上面看出，因为返回值和参数类型的不同，函数类型并不是固定的，所以必须要为函数单独创建类型实例。  
看一下llvm::FunctionType的构造函数：
```
// private
  FunctionType(Type *Result, ArrayRef<Type*> Params, bool IsVarArgs);

// public
  /// This static method is the primary way of constructing a FunctionType.
  static FunctionType *get(Type *Result,
                           ArrayRef<Type*> Params, bool isVarArg);
```
正如之前提到的，llvm中很多地方采用了隐藏构造函数，提供类方法创建实例的技巧。  
参数格式如下：

- Type* Result：顾名思义，这是返回值的类型。  
- ArrayRef<Type*>：参数类型
- IsVarArgs：是否为可变参数；一般情况都是false。  
             针对类似printf这样参数不固定的情况，这个值为true。 

