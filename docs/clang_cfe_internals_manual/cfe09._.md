# 设计哲学
## 不变性
Clang的AST节点（类型，声明，语句，表达式等等）一般是创建后就不会再变的。这样有以下几个好处：
- 节点的"含义"可以创建时就进行规范化，并且不会被后续新增的信息影响。比如，我们规范化类型，使用一个规范的表达式形式来决定两包含了各自独立的表达式的函数模板，是否是代表同一个实体。
- AST节点可以复用。比如，我们复用类型节点来描述同一个类型（但是会给每一个类型写下的地方维护各自的TypeLoc信息），也会在模板实例化时复用Stmt和Expr节点。
- AST节点与AST文件之间进行序列化/反序列化更简单：我们不需要追踪AST节点的修改，也不用序列化单独的“更新记录”。

不过对这个一般化的目标，也有一些异常情况，比如：
- 对于一个多次声明的实体，第一个声明包含指向该实体最近的声明的指针。这个指针在分析出更多声明的时候需要跟着变。
- 在命名空间的声明构建之后，名字查找表需要跟着一起变。
- 我们设计上倾向于为一个模板的一个实例只生成一份声明，而不是根据定义的不同声明多次。那么模板实例化就会使得已经生成好的实例也跟着一起改变。
- 声明的一部分需要单独实例化（包括默认参数和异常特性化），这些实例化也会修改已经存在的声明。

这些情况比较零散；应该尽量避免出现可变的AST。  
作为设计原则的一个结果，我们尽量不提供AST state的set接口（有一些情况需要提供：在AST节点创建之后，"publish"作为完整AST的一部分之前立即修改，或者语法要求的时候）。

## 忠实性
AST会提供初始源代码的一个忠实表达。尽量只会用AST内部的或者再次构建信息来进行Refactor。这就要求AST表达不能解语法糖，也不能因为更清楚的表达而对代码进行解wrap。  
例如，CXXForRangeStmt 直接表达成一个range方式的语句，也包含range和迭代器相关的声明。但是不包含解语法糖之后的for语句。  
一些AST节点（比如ParenExpr）只包含语法信息，另一些（比如ImplicitCasrExpr）只包含语义信息；但是绝大多数的节点都是同时包含语法和语义信息。继承就是用来表达语法不同（但是相关）而语义相同的节点。  

## Type类和子类
Type类是AST的一个重要部分。Type对象通过ASTContext类访问，会在需要的时候隐式创建唯一类型信息。Type有一些不言自明的特性：1) Type不包含type修饰符，比如const，volatie等（参考QualType）2) type隐式包含typdef信息。Type创建之后就不可变了（与声明不同）。  
C语言中的typedef信息的存在略微增加了语义分析的复杂程度。问题在于，我们希望能捕获typedef信息，以便于在AST中优雅的表达出来，但是语法操作需要“贯穿“所有的typedef信息。比如下面的代码：
```
void func() {
  typedef int foo;
  foo X, *Y;
  typedef foo *bar;
  bar Z;
  *X; // error
  **Y; // error
  **Z; // error
}
```
上面的代码不能通过编译，然后，我们希望在我们注释的地方可以出现错误诊断信息。本示例中，我们想看到如下信息：
```
test.c:6:1: error: indirection requires pointer operand ('foo' invalid)
  *X; // error
  ^~
test.c:7:1: error: indirection requires pointer operand ('foo' invalid)
  **Y; // error
  ^~~
test.c:8:1: error: indirection requires pointer operand ('foo' invalid)
  **Z; // error
  ^~~
```
这个示例看起来有点“傻”，不过主要是说明一点：我们希望保留typedef信息，那么我们可以生成std::string的错误而不是std::basic_string<char, std::......>的错误。如果要做到这一点，就需要适当的维持typedef信息（比如，知道X的type是foo，而不是int），并且也能适当的扩展到不同的操作符中（比如，知道*Y的类型是foo, 不是int）。为了保持这些信息，这类表达式由TypedefClass类的实例来描述，该实例用来说明这类表达式是一个针对foo类型的typedef。  
使用这种方式表达一个类型，对于错误诊断帮助很大，因为一般用户自定义的类型往往都是能最容易感知的。不过这里还有2个问题：需要使用不同的语法检查来跳过typedef信息，判断type对应的真实类型；需要一种高效的方式来跳过typedef信息，判定2个类型是否结构上完全一致。这两个问题可以通过公认类型的思想解决。  

## 公认类型
每个Type类都有一个公认类型指针。针对最简单的，不包含typedef的类型（比如int, int*, int\*\*等），这个指针就指向其自身。针对含有typedef信息的类型（比如上面例子的"foo","foo*","foo\*\*","bar"），公认类型指针指向的是与其结构一致的，不包含typedef信息的类型（比如，上面几个类型的指针各自指向：“int”, “int*”, “int**”, and “int*”）。  
这个设计可以使得访问类型信息时有常数的时间复杂度（只需解引用指针即可）。比如，我们可以很容易通过解引用+指针比较的方式，判定foo\*和bar为同一类型（都指向最普通的int\*类型)。  
公认类型也带来一些复杂性，需要小心处理。一般情况下，isa/cast/dyn_cast等操作符是不应该在检查AST的代码中出现的。比如，类型检查需要保证\*操作符的操作数，一定是指针类型。那么，这就没法正确地检查这样的表达式“isa<PointerType>(SubExpr->getType())"，因为如果SubExpr->getType()是一个typedef的类型，那么这个isa的推断就会出错。  
这个问题的解决方案是，在Type类中提供一个helper方法来检查其属性。本例中，使用SubExpr->getType()->isPointerType()来进行检查应该是正确的。如果其公认类型是一个指针，那么这个方法就会返回true，唯一需要注意的地方是不要使用isa/cast/dyn_cast这些操作符。  
第二个问题是，如何访问这个指针对应的类型。从上面的例子继续，\*操作的结果类型，必然是该表达式所指向的类型（比如，定义bar vx, \*vx的类型，就是foo，就是int）。为了找出这个类型，我们需要找到可以最佳捕获这个typedef信息的PointerType的实例。如果表达式本身的类型就是字面上的PointerType，那么就可以直接返回类型；否则我们必须沿着typedef信息挖下去。比如，若一个子表达式的类型是foo\*，那么我们就返回这个类型。如果类型是bar，我们希望返回的是foo\*（但是不是int\*）。为了达到这一目的，Type类提供了getAsPointerType()方法来检查类型本身是不是指针，如果是的话，就直接返回；否则会找一个最佳匹配的；如果不能匹配就返回空指针。  
这个结构有一点不是很清楚，需要好好的研究下才能明白。  

# QualType类
QualType类是平凡的值类型，特点是小，一般通过值传递，且查找起来很高效。其思想为保存类型本身，以及类型限定符（比如const, volatile, restrict或者根据语言扩展的其他限定符）概念上，QualType包含由Type*指针和指明限定符的bit位组成的pair。  
用bit表示限定符，在增删改查方面效率都很高。  
将限定符的bit和类型分离保存的好处是，不需要针对不同的限定符也复制出不同的Type对象（比如，const int或者volatile int都只需要指向同一个int类型），这就减少了内存开销，在区分Type时也不需要考虑限定符信息。  
实现上，最常见的2个限定符（const和restrict）保存在指向Type的指针的最低位，还包含一位标识是否存在其他的限定符（新的部分要分配在堆上）。所以QualType的内存size和指针基本一致。  
> QualType在这里：clang/include/clang/AST/Type.h。
> ```c
> class QualType {
>   ...
>   // Thankfully, these are efficiently composable.
>   llvm::PointerIntPair<llvm::PointerUnion<const Type *, const ExtQuals *>,
>                      Qualifiers::FastWidth> Value;
>   ...
> };
> ```
> 其中，PointerIntPair这个类将一个指针和一个int合在一起存储，低位bit放int，高位放指针本身；在保证指针值完整保留的场景下可以这样来节省空间。     

# 声明name信息
DeclarationName类用来描述Clang中的一个声明的name。C系语言的生命有多种方式。大多数的声明name都是最简单的标识符，比如f(int x)中的'f'和'x'。C++中，声明name还包括类构造函数（struct Klass { Klass(); }中的 Klass），类析构函数（~Klass），重载的操作符（operator+），以及转换函数(operator void const *)。在Objective-C中，声明name包括，OC的方法，包括方法名和参数名。因为因为上面这些全部的实体，包括变量，函数，OC方法，C++构造析构函数，操作符之类都由Clang的标准NamedDecl类描述，所以就设计了DeclarationName类来高效的表达不同种类的name）  
对于一个DeclarationName的实例N，N.getNameKind()会返回一个值来说明N中的name是哪一种。包括下面10个选项（都是在DeclarationName类的内部）：
- Identifier  
普通标识符。可通过N.getAsIdentifierInfo()获取对应的IdentifierInfo*指针
- ObjCZeroArgSelector, ObjCOneArgSelector, ObjCMultiArgSelector  
OC的selector信息（暂略）
- CXXConstructorName  
C++的构造器的name，可通过N.getCXXNameType()来获取该构造器准备构造的类型。这个类型是一个公认类型，因为所有的构造器的name是相同的。
- CXXDestructorName  
C++的析构器的name，可通过N.getCXXNameType()来获取该构造器准备构造的类型。这个类型是一个公认类型。
- CXXConversionFunctionName  
C++转换函数，转换函数的name是其转换目标的类型，比如：operator void const *。可通过N.getCXXNameType()获取转换目标的类型，这个类型是一个公认类型。
- CXXOperatorName     
C++重载操作符的类型。name是其拼写，比如：operator+或者operator new []。可通过N.getCXXOverloadedOperator()获取重载的操作符类型（OverloadedOperatorKind的值）
- CXXLiteralOperatorName  
C++11中的字面操作符。name是其定义的后缀，比如operator "" _foo的name是_foo。使用N.getCXXLiteralIdentifier()来获取对应标识符的IdentifierInfo*信息。  
- CXXUsingDirective  
C++ using指令。实际上using指令不算是NamedDecl类，放到这里是因为实现上方便用DeclContext类来保存其值。

> OverloadedOperatorKind见：clang/include/clang/Basic/OperatorKinds.h与clang/include/clang/Basic/OperatorKinds.def

DeclarationName实例很容易被创建、复制、比较。通常情况下（标识符，0或1参数的OC selector），只需要一个指针长度的存储空间，其他情况则需要紧密、独立的存储。DeclarationName可以通过bit比较来确定是否相等，也可以通过>,<,>=,<=等操作进行排序（主要指标识符，可以通过字母排序；其他类型则排序不确定）也可以被存放在llvm的DenseSet和DenseMap中。  
DeclarationName实例根据其name的种类不同，有不同的创建方式。普通的标识符和OC selector可以隐式转换为DeclarationName；C++构造器，析构器，重载操作符，转换函数则是从DeclarationNameTable获得的ASTContext::DeclarationNames实例。getCXXConstructorName, getCXXDestructorName, getCXXConversionFunctionName, getCXXOperatorName会各自返回对应的C++特定函数name。  

# 声明上下文
程序中的每个声明都存在对应的声明上下文，比如翻译单元TU，命名空间，类，函数。声明上下文在Clang中由DeclContext类代描述，不同的声明上下文的AST节点（TranslationUnitDecl, NamespaceDecl, RecordDecl, FunctionDecl等）都会继承该类。DeclContext类提供了处理声明上下文的一些通用能力。  

- 声明的源码视图与语义视图  
DeclContext提供了存储在其中的声明信息的两种视图。源码视图可以准确表达输入的源码，包括多次声明（见下面的二次声明与重载）；语义视图则表达了程序的语义信息。这两个视图在语义分析与构建AST的过程中会同步更新。
- 上下文中的声明信息  
每个声明上下文都包括一些声明信息，比如C++的类（由RecordDecl类表达）中包含不同的成员函数，字段，内嵌类型等等。所有这些声明都可以保存在DeclContext中，可以通过[DeclContext::decls_begin(), DeclContext::decls_end())（左开右闭）迭代器遍历这些声明。这个机制提供了声明的源码视图
- 声明的查找  
DeclContext结构提供了高效的name查找能力。比如，可以在一个命名空间N中查找N::f，这个查找基于一个延迟构造的数组或者哈希表实现。查找操作提供了声明的语义视图。
- 声明的所有权  
DeclContext掌管着其上下文中的声明的所有权，负责其内存空间的管理，序列化，反序列化。

所有的声明都保存在声明上下文中。可以通过DelContext查询声明的信息，也可以通过Decl实例反向查找其所在的DeclContext对象，可参考“词法和语义上下文”了解如何解析context的信息。  

## 二次声明与重载
在TU内部，一个实体可以被声明多次。比如，可以声明一个函数f，之后二次声明为一个内联函数。
```
void f(int x, int y, int z = 1);
inline void f(int x, int y, int z) { /* ...  */ }
```
f在声明上下文的源码视图和语义视图中的表达式不同的。源码视图中，所有的二次声明都存在，按照源码中的顺序排列，方便需要查看代码结构的客户端使用。在语义视图中，因为覆盖的缘故，只有后面的内联函数f是可以被查找的。
（注意，存在f在语句块中，或者作为友元被声明等情况；通过f进行查找时，不一定就是返回最靠后的这个）
在语义视图中，函数重载会显式表达出来。比如下面的声明：
```
void g();
void g(int);
```
DeclContext::lookup会返回一个DeclContext::lookup_result，包含一个range的指向"g"的声明的迭代器。对程序进行语义分析，但是不关心实际的代码的客户端，可以使用语义视图。

## 词法和语义上下文
每个声明都有两个潜在的上下文：词法上下文，对应声明上下文的代码视图；语义上下文，对应声明上下文的语义视图。可以通过Decl::getLexicalDeclContext返回源码视图的DeclContext，Decl::getDeclContext返回语义视图的DeclContext；返回的都是DeclContext实例的指针。对于大多数的声明，返回的这两个上下文是一致的，比如：
```
class X {
public:
  void f(int x);
};
```
X::f对应的词法和语义上下文都是X的声明上下文。接下来，在X之外定义X::f
```
void X::f(int x = 17) { /* ...  */ }
```
f的定义的词法和语义上下文就不同了。词法的上下文就是这个定义所在的代码对应的上下文，即包含X的TU的上下文；该上下文中，根据[decls_begin(), decls_end())遍历可以找到X::f的声明信息。语义上下文依旧是X的声明上下文，原因是f在语义上是X的成员。通过DeclContext进行名字查找可以找到X::f的定义（包括声明信息和默认参数）

## 透明的声明上下文
C和C++中，有一些上下文是这样：其中的声明在逻辑上放在其他声明之内，在实际的名字查找时，需要逃逸到紧外层的作用域（从而能被查找）。最明显的示例是枚举类型，比如：
```C
enum Color {
  Red,
  Green,
  Blue
};
```
上述示例中，Color是一个枚举，对应一个包含Red, Green, Blue这几个枚举值的声明上下文。遍历该枚举中的声明时，可以获得Red, Green, Blue。但是，在Color之外，可以使用Red这个枚举值却不需要限定名。比如：
```c
Color c = Red;
```
其他的场景也有类似的情况。比如，使用{}表示链接规格。
```c
extern "C" {
  void f(int);
  void g(int);
}
// f and g are visible here
```
为了保持代码级的准确性，我们把链接规格和枚举类型按照包含了各自声明（Red, Green, Blue和f ,g）的声明上下文处理。但是，这些声明都在该上下文的外部作用域可见。  
这些语言特性（包括下面提到的其他的），有类似的要求：声明在相应的词法上下文中，但是在外部作用域进行名字查找时也要能找到。这个特性通过透明声明上下文实现（参考DeclContext::isTransparentContext()），这类上下文中的声明在在其紧邻的最近一个非透明的上下文中可见。这就是说，这类声明的词法和语义上下文都是其自身，但是这类声明则会在外层中直到第一个非透明的上下文中都可见。    
透明上下文包括：
- 枚举（不包括C++11的限定作用域枚举）
```
enum Color {
  Red,
  Green,
  Blue
};
// Red, Green, and Blue are in scope
```
- C++链接规格
```
extern "C" {
  void f(int);
  void g(int);
}
// f and g are in scope
```
- 匿名union和struct
```
struct LookupTable {
  bool IsVector;
  union {
    std::vector<Item> *Vector;
    std::set<Item> *Set;
  };
};
LookupTable LT;
LT.Vector = 0; // Okay: finds Vector inside the unnamed union
```
- C++11 inline namespace
```
namespace mylib {
  inline namespace debug {
    class X;
  }
}
mylib::X *xp; // okay: mylib::X refers to mylib::debug::X
```
## 多段定义声明上下文
C++的命名空间有个比较有意思的属性：多次定义，各段定义的声明在效果上会最终合并起来（从语义角度看）。比如，下面两段代码是等价的。

```c
// Snippet #1:
namespace N {
  void f();
}
namespace N {
  void f(int);
}

// Snippet #2:
namespace N {
  void f();
  void f(int);
}
```
在Clang的表达中，Snippet #1的部分是2个分离的NamespaceDecl，每个都包含一个声明了f的上下文。但是，从语义视图来看，在N中对f的名字查找会将两个声明都返回。  
DeclContext可以内部管理多段定义的声明上下文。DeclContext::getPrimaryContext可以取出“主要”的上下文，这个上下文用于记录语义视图的声明查找表。给定一个DeclContext，调用者可以通过DeclContext::collectAllContexts获取语义上与该Context连接的所有上下文，也包括其自身，返回结果顺序和源码顺序一致。这类的方法只有在内部查找，插入DeclContext对象时使用，大部分的外部客户端都不需要调用之。  
同一个实体可以在不同的模块中多次定义，那么描述同一个类的CXXRecordDecl也可以定义多次。在这种场景下，只有其中一个定义会被Clang视作真正的定义，其他的则会被视作包含成员声明的类声明。不同定义中对应的成员会按照二次声明或者合并方式处理。（注：实际上不能在同一个namespace的不同段中定义同名的类）  

# ASTImporter
ASTImporter类将AST节点从一个ASTContext导入另一个。可参考ASTImporter和import算法描述了解更多信息。

## 抽象语法图
和名字不同，Clang的AST并不是一个真的树，而是带回路的有向图。有向图的一个示例是ClassTemplateDecl与其模板实例化后的CXXRecordDecl。实例化之后的CXXRecordDecl描述了该类模板的成员和方法，ClassTemplateDecl则记录了模板相关的信息，比如，模板参数等。ClassTemplateDecl::getTemplatedDecl()可以获得实例化的CXXRecordDecl类，CXXRecordDecl::getDescribedTemplate()反过来可以获得其所实例化的模板类；所以这两个模板与实例的节点之间就存在一个回路。AST中也存在其他不同的回路。

## 结构等效性
导入AST节点的操作，会将节点整个复制到目标ASTContext中。复制这个操作指我们会在目标的Context中创建一个新节点，并且设置其属性和源节点相等。在复制之前，必须保证源节点和目标Context中的已存在节点之间没有结构等效性；如果有的话，那么复制就没有区别，就跳过复制。
结构等效性的正式定义：两个AST节点满足以下条件时可以认为是结构等效的。
- 同为内置类型，且类型相同（比如int和int是结构等效的）
- 同为函数类型，所有参数结构等效
- 同为记录类型（struct/class之类），其所有字段按定义顺序，标识符名字一致，且类型为结构等效。
- 变量或者函数声明，标识符名字一致，类型结构等效。

在C语言中，如果两个类型是compatible的，那么他们是结构等效的。C++标准中没有compatible的概念。这里我们拓展了结构等效的定义来处理模板和其实例化的场景：除了检查前述属性，还需要检查模板形参/实参的等效性。  
结构等效性检查逻辑可以（并且目前是）独立于ASTImporter，换句话说，clang::Sema也在使用之。  
节点之间的等效性有时会依赖于其他节点间的等效性，实现上，这个检查是在沿着图的边并发执行的。同时在图的不同节点上遍历，实际上采用的是类似BFS的实现。比如，我们要计算<A,B>的等效性，然后如果计算过程中走到了计算<X,Y>的话，那么说明：
- A和X是来自同一个ASTContext
- B和Y是来自同一个ASTContext
- A和B不一定来自同一个ASTContext
- 如果A == X 且 B == y（指针相同），那么（出现了回路）：A和B结构等效 <=> 从<A,B>到<X,Y>过程的所有节点都是结构等效的。

比较两个类或者枚举，而其中一个是未完成的，或者包含未完全加载的外部字面声明，那么就不能退一步只比较已包含的声明。这种情况下，我们就认为他们是否等效，取决于名字是否一样。这也是我们比较定义的前向声明的方式。  
（注：代码中，如果一个定义的提前声明出现了2次，那么可以认为这两个声明一样的，即结构等效的）

## 二次声明链
低版本的ASTImporter的合并机制会合并声明信息，即，其尝试只保留一个声明，而不是维持一个二次声明链。这个目标是想简单跳过函数原型而直接导入函数定义。这里举例来说明这个目标的问题，考虑一个空的目标context，以及下面这个源context中的virtual函数声明：     
```c
struct B { virtual void f(); };
void B::f() {} // <-- let's import this definition
```
如果直接合并掉声明信息，直接导入定义。那么，导入的结果就是一个实际为定义的声明，但是声明的isVirtual()方法就会返回false，原因是这个定义本身不是virtual的，而是函数原型的属性。  
为了解决这个问题，要么就给这个定义设置virtual相关的flag（但这样就等于创建一个不应该被创建的AST），要么就是将函数的整个二次生命链导入。新版本的ASTImporter采用了后者，按照在源context中的顺序，导入所有的函数声明，不管是定义还是原型。  
如果在目标context中已存在一个定义，那么就不能导入新的定义，而是使用现有的定义。不过我们可以导入原型：将新的原型链到现有的定义后面；不管什么时候，只要导入了一个新的原型，就会将该原型加到二次声明链后面，那么在一些特定场景下，可能会导致很长的声明链，比如，从多个不同的TU中，导入了包含相同头文件的原型。   
为了减少长链带来的影响，可以比较原型是否相同并进行合并。  
声明链的工作方式使得在复制时，会复制来自源AST的所有信息。尽管如此，有一个关于成员函数的问题：对于“自由”函数的原型可以很多个，但是类成员函数的原型只能有一个。
```c
void f(); // OK
void f(); // OK

struct X {
  void f(); // OK
  void f(); // ERROR
};
void X::f() {} // OK
```
所以，类成员函数的原型必须要合并，不能简单将新的原型链到已有的类中的原型上。考虑下面的上下文：
```c
// "to" context
struct X {
  void f(); // D0
};

// "from" context
struct X {
  void f(); // D1
};
void X::f() {} // D2
```
当我们从源context中导入f的原型和定义时，得到的声明链像这样：D0 -> D2'，D2'是D2的一个拷贝。  
一般情况下，在导入声明时（比如枚举和类），会将新导入到声明添加到已存在的声明链之后（如果他们是结构等效的）。但是，并不会和处理函数一样，将所有的调用链都导入。截至目前，我们并未看到在前向声明中，出现其他和成员函数的virtual标记类似的情况，不过未来也许会有变化。  

## 导入过程的遍历
节点相关的导入机制在ASTNodeImporter::VisitNode()相关函数中实现，比如VisitFunctionDecl()。在导入声明时，首先会导入用于调用该节点的构建器所需要的信息，所有需要后续设置的值在节点被创建之后设置。比如，针对FunctionDecl的情况，首先需要导入其声明所在的声明上下文，然后创建FunctionDecl这个类，再之后才导入函数的实现。这说明，在AST节点之前实际存在隐式的依赖关系；这些依赖关系决定我们从源头中按照何种顺序访问节点。实现中，按照常规图遍历算法（比如DFS）的思想，导入时会在ASTImporter::ImportedDecls中记录已经访问过的节点，创建新节点时，会直接加入到ImportedDecls中，只有在将新节点加入之后，才能处理新的声明的导入，否则会没法处理循环依赖的情况。为了强制保证按照上面的顺序执行，所有的AST节点的构造器都会被包装在GetImportedOrCreateDecl()。这个包装器保证新创建的节点会立马被标记为已导入；另一方面，如果一个声明被标记为已导入，那么就直接返回该声明在目标context中的对应节点。所以，直接调用一个声明的::Create()方法会导致错误，不允许这么做。  
即便使用了GetImportedOrCreateDecl()，如果导入方式错误，也可能出现导入无限递归的情况。考虑导入A时，导入B需要先于A的创建之前执行（A的构造器可能依赖B的引用），然后导入B也依赖A的先执行。为了保证针对模板的场景，也可以跳出循环依赖，需要一些额外的关注：只有在CXXRecordDecl创建之后，才能标记为该模板已被实例化。实践中，在目标上下文中创建节点之前，需要防止导入A的构造器不需要的节点。  

## 错误处理
每个导入的函数要么返回一个llvm::Error，要么返回一个llvm::Expected<T>对象。这样写强制调用者去检查导入函数的返回值。如果在导入过程中出错，就返回错误。（特殊情况：在导入类的成员时，会收集每个成员各自的错误，并且拼接到一个Error对象中）在处理声明时，会先缓存住这些错误。处理下一个导入的调用时，就会返回这些错误。这样，使用这些库的客户端就会拿到一个Error对象，而它们必须对其进行处理。  
在导入一个特定声明时，可能出现在识别到错误之前，已经提前创建了若干个AST节点。这种情况下，错误会返回给调用者，但是这些“脏”节点会保留在目标上下文中。理想状况下是不应该有这样的节点的，但是可能在创建节点时，还并没发现错误，而是之后的过程中才出现错误的。因为AST节点是不可变的（大部分情况是为了防止已存在节点被删除），会将这些节点标记为错误。  
源context中声明关联的错误会记录在ASTImporter::ImportDeclErrors中，目标context的声明关联错误记录在ASTImporterSharedState::ImportErrors中。注意，可能有一些ASTImporter对象会从不同的源上下文中导入到同一个目标上下文，这种情况下，他们会共享目标上下文中的关联错误。  
错误出现时，会在调用栈，和所有依赖节点上传播。目前会尝试将接地那标记为错误，方便客户端处理，而这无法处理有循环依赖的情。针对循环依赖，必须要记录该回路上的所有节点的错误信息。
导入路径是调用导入方法时，访问节点的列表。如果A依赖B，那么路径中会记录一条边A->B，从导入函数的调用链中可以看到基本一致的路径。
考虑下面的AST，->表示导入的依赖关系（所有的节点都是声明）
> 注：下图中还包含了B->E，通过文字表示不太明显
```c
A->B->C->D
   \->E
```
我们希望导入A。导入过程使用DFS思想，我们按照ABCDE的顺序访问。访问过程中，可能会出现如下的导入路径
```c
A
AB
ABC
ABCD
ABC
AB
ABE
AB
A
```
如果访问E的时候出现了错误，那么我们对E设置一个错误，然后缩到对B，再到对A
```c
A
AB
ABC
ABCD
ABC
AB
ABE // Error! Set an error to E
AB  // Set an error to B
A   // Set an error to A
```
不过，因为导入CD时并没有错误，CD也是和AB独立的，那么就不能对CD设置错误。那么，在导入结束时，ImportDeclErrors包含了对ABE的错误，不包含CD。

现在处理一下循环依赖的情况，考虑下面的AST
> 注：下图中还包含了B->E，通过文字表示不太明显
```c
A->B->C->D
   \->E
```
在访问过程中，如果E有错误，则会有下面的导入路径，ABE都被设置为错误，但是C怎么处理。
```c
A
AB
ABC
ABCA
ABC
AB
ABE // Error! Set an error to E
AB  // Set an error to B
A   // Set an error to A
```
这里，BC都依赖A，这就说明我们也必须对C设置错误。如果从调用栈回溯的话，A被设置成错误，而依赖A的节点也要设置错误，但是出错时，C并不在这个导入路径上，C是之前被加入过。这个场景只有访问出现循环时才会遇到。如果没有循环，常规的方法是把Error对象传递给调用栈上层。所以这就是每一次声明访问中出现的循环都要记录的原因。  

## 查找问题
从源上下文导入声明时，需要检查在目标上下文中是否存在名义相同，且结构等效的节点。如果源上下文的节点是一个定义，目标中找到的也是一个定义，那么就不在目标上下文中创建新的节点，而是标记目标上下文中的节点为已导入。如果找到的定义和源上下文中的定义名字一样，但是不是结构等效的，那么（C++的话）就会出现一个违反ODR的错误。如果源节点不是定义，就将其添加到目标节点的二次声明链。这个行为在合并包含相同头文件的不同TU对应的AST时很有必要。比如，（注：同一个类型）我们希望只存在一个std::vector的定义，即便在多个TU中都包含了\<vector\>头文件。  
为了找到一个结构等效的节点，可使用常规的C/C++查找函数：DeclContext::noload_lookup()和DeclContext::localUncachedLookup()。这些函数遵循C/C++的名字隐藏的原则，一些特定的声明在声明上下文是无法找到的，比如unamed声明（匿名结构体），非第一次出现的友元声明，模板特化等。这个问题可能导致如果支持常规的C/C++的查找，在合并AST时，会创建冗余的节点，冗余的节点又会导致在节点间结构等效型判定时出错。因为上面这些原因，创建一个查找类，专门用于注册所有的声明，这样这些声明就在导入之后，就可以被查找了。这个类叫：ASTImporterLookupTable。这个查找表会在导入同一个目标上下文的不同ASTImporter之间共享。这也是说明只能通过ASTImporterSharedState进行导入相关查询的原因。

### ExternalASTSource
ExternalASTSource是和ASTContext关联的抽象接口。它提供了通过迭代或者名字查找来访问声明上下文中的声明的能力。依赖外部AST的声明上下文需要按需加载其声明信息。这就说明（在未加载时）声明的列表（保存在链表中，头是DeclContext::FirstDecl）可能是空的，不过类似DeclContext::lookup()的成员函数可能会初始化加载流程。  
一般来讲，外部源代码是和预编译头文件相关的。比如，如果从预编译头文件中加载一个类，那么该类的成员只有在需要在该类的上下文中进行查找时才会被加载。  
考虑LLDB的情况，一个ExternalASTSource接口的实现类，是和对应表达式所在的AST上下文相关联的。这个实现是通过ASTImporter被发现的。通过这种方式，LLDB可以复用Clang的分析机制来从调试数据（比如DWARF，调试信息存储格式）中合成底层的AST。从ASTImporter的角度看，这意味着源和目标上下文中，可能包含存储了外部词法信息的声明上下文。如果目标上下文中的DeclContext对象包含了外部词法信息的存储，就必须特殊处理已经被加载的声明信息。否则，导入过程会变得不可控。比如，使用常规的DeclContext::lookup()在目标上下文中查找存在的声明，在导入声明的过程中，lookup方法会出现递归调用从而导致出现新的导入操作。（在初始化一个尚未注册的查找时，已经开始从源上下文中导入了）所以这里需要用DeclContext::noload_lookup()来代替。

## 类模板的实例化
不同的TU可能各自包含对相同模板参数的实例化，但是实例化后的MethodDecl和FieldDecl集合是不同的。考虑如下文件：
```c
// x.h
template <typename T>
struct X {
    int a{0}; // FieldDecl with InitListExpr
    X(char) : a(3) {}     // (1)
    X(int) {}             // (2)
};

// foo.cpp
void foo() {
    // ClassTemplateSpec with ctor (1): FieldDecl without InitlistExpr
    X<char> xc('c');
}

// bar.cpp
void bar() {
    // ClassTemplateSpec with ctor (2): FieldDecl WITH InitlistExpr
    X<char> xc(1);
}
```

在foo.cpp中，使用了(1)这个构造器，显式将a初始化为3，那么InitListExpr {0}这个初始化表达式就没被使用，也没有实例化相关的AST节点。然后，在bar.cpp中，我们使用了(2)这个构造器，没有使用初始化a的构造器，那么就会执行默认的InitListExpr并实例化。在合并foo.cpp和bar.cpp的AST时，就必须为X\<char\>这个模板实例化创建全部所需的节点。也就是说，如果找到了ClassTemplateSpecializationDecl对象，就需要把源上下文中，ClassTemplateSpecializationDecl对象的所有字段采用这个方式合并：如果一个InitListExpr不存在就复制。这个机制也适用于默认参数和异常规格的实例化。  

## 声明可见性
在导入外部可见的全局变量时，查找过程会找到同名变量，但是却是静态可见的。明确一下，就是不能把他们放到同一个二次声明链中。这个情况对函数也适用。而且，还需要特殊注意匿名命名空间的枚举、类。那么，我们会在查找结果中过滤，只考虑和当前导入的声明具有相同可见性的结果。  
这里认为，匿名命名空间的两个变量，只有来源于同一个源AST上下文的才认为是可见性相同的。  

## 冲突名字的处理策略
导入过程中，我们会查找是否存在有同名的声明，并且根据其可见性进行过滤。如果找到了声明，并且和源中的不是结构等效的，那么就报一个名字冲突的错误（C++中的ODR违规）。在此场景中，会返回Error对象并且将这个对象设置到声明中。不过，一些调用ASTImporter的客户端可能会要求不同的处理方式，比如不需要太保守的，更自由一点的错误处理策略。  
比如，代码的静态分析的客户端，会倾向于即便出现名字冲突时也创建节点。对进行特定工程进行CTU(Cross Translation Unit)分析时，必须知道可能存在全局的声明和来自其他TU的声明冲突，但是这些全局声明并不被本TU外部引用的情况。理想情况，这一部分声明需要放在匿名命名空间中。如果我们比较自由的处理这类冲突，那么CTU分析可以发现更多的结果。注意，支持选择不同的名字冲突处理策略的特性还尚未完善。

# CFG类
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

# Clang AST中的常量折叠
在Clang前端中，有一些场景下，常量和常量折叠是很重要的。首先，通常情况下，希望能让AST尽可能贴近源代码。如果代码中写了“5+4”，我们希望在AST描述这两个常量的加法操作，而不是直接折叠成“9”。所以，不同方式处理常量折叠，其最终会通过树遍历的方式来实现，从而可以处理不同的场景。
> 注：5+4在AST中，会通过5,+,4三个AST节点表示，所以5+4的处理需要树的遍历）。  

不过，有一些场景是要求C/C++必须进行常量折叠的。举例，C标准以很精细、特殊化的方式定义了“整数常量表达式(i-c-e)”。语言中很多场景有需要i-c-e（比如bitfield的大小，case语句的值等），这样就必须进行常量折叠来进行语义检查（比如，判断bitfield的长度是否非负，case语句没有重复）。希望Clang可以很“教条”的方式处理：诊断出需要使用i-c-e而没有使用的场景，但是只有在使用-pedantic-errors时才报错，否则都通过编译。  
为了兼容真实世界的代码，需要有一点取巧的方式。考虑一种特殊情况，gcc的某个历史版本，会接受一个巨大的表达式超集作为i-c-e，然后，很多真实世界的代码都依赖这个不太幸运的特性（包括比如glibc的头文件）。gcc会将任何能被折叠成一个整数常量的都进行该优化。比如，gcc会将case X-X语句优化成case 0，即便x是一个变量。  
另一个问题是，常量是如何和编译器支持的扩展交互的，比如__builtin_constant_p, __builtin_inf, __extension__和其他的。C99没有明确指定这些扩展的语义，i-c-e的定义也没有包含这些。不过，在实际开发时，这些扩展经常会用到，所以必须有合适的方式处理。  
最后，这不仅仅是关于语义分析的问题。代码生成器和其他的客户端也需要具备常量折叠的能力（比如，初始化全局变量），也必须处理C99规定的超集。而且，这些客户端会从扩展中受益。比如，我们知道foo() || 1的计算结果一定是true，但是因为有边际效应，就不能直接替代成true。

> 关于上面的gcc历史版本的特性说明：  
> gcc在4.x版本中，出现过过度“折叠”优化，导致正常的计算出现错误的情况。比如这个bug：  
> <https://gcc.gnu.org/bugzilla/show_bug.cgi?id=57829>  
> 这些内容不在本文的范围内，这里只是提一下。  

## 实现目标
在尝试过多个不同的目标之后，最终综合出了一个设计（注意，编写本文时，不是所有的都被实现了，这一部分是一个设计目标！）。最基本的目标是定义一个简单的递归计算方法（Expr::Evaluate），在AST/ExprConstant.cpp中实现。给定一个“标量"类型（比如整数，浮点，复数，指针）的表达式，这个方法会返回下面的信息：  
- 此表达式是否为i-c-e/一个没有副作用的通用常量/一个有副作用的通用常量/一个不可计算或折叠的值
- 这个表达式是否是可以计算的，（如果可以计算）此方法会返回APValue代表计算结果
- 如果这个表达式不能执行，这个方法会返回表达式中所存在的其中一个问题。信息中还包括描述问题位置的SourceLocation，以及解释该问题的诊断ID。这个诊断具有EXTENSION类型。

> 副作用：这里指常量折叠中用到的表达式可能产生的附加影响。比如下面的代码：
> ```
> int x = 3;
> int retConstant() {
>   x = 4;
>   return 5;
> }
>
> int func() {
>   int y = 3 * retConstant();
>   return y;
> }
> ```
> 这里不能直接将y或者func()的调用折叠成15，否则x = 4就不会执行，从而导致程序错误。  

这些信息可以为客户端提供所需的一些灵活性，最终也会有针对不同扩展的辅助方法。比如，Sema类需要有一个Sema::VerifyIntegerConstantExpression方法，这个方法调用了Evaluate。如果这个表达式不能折叠，就报告一个错误，然后返回true。如果这个表达不是i-c-e，这个EXTENSION诊断就报告出来。最后，如果AST没问题的话就返回false。  
其他的客户端可以通过不同的方式使用这些信息，比如，代码生成可以直接使用折叠后的结果。  

## 扩展
本节描述一下Clang在常量计算时支持的不同的扩展：
- `__extension__`：这个表达式会尝试将可以被计算的子表达式替换成i-c-e。
- __builtin_constant_p：这个方法在操作数可以被计算为一个整数、浮点、复数的数字值（而不是指针转换成整形），或者是否是某个字符串首字母的地址（会转换成其他类型）时返回true。特殊例子，如果__builtin_constant_p 是（被自动加了括号）条件操作表达式的条件，那么只有为真的那一部分被考虑，也被折叠。
- __builtin_choose_expr：这个情况
- __builtin_classify_type: 这个一定会返回一个i-c-e
- __builtin_inf, nan, ...: 这些被看成是浮点数常量
- __builtin_abs, copysign, ...: 按照通用的常量表达式处理常量折叠
- __builtin_strlen 和 strlen: 参数为字符串字面常量时，按照i-c-e处理常量折叠

---------------------    

[原文](https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html#the-ast-library)