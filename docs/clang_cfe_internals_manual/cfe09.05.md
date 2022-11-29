
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