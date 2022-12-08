
# 声明name信息
DeclarationName类用来描述Clang中的一个声明的name。C系语言的声明有多种方式。大多数的声明name都是最简单的标识符，比如f(int x)中的'f'和'x'。C++中，声明name还包括类构造函数（struct Klass { Klass(); }中的 Klass），类析构函数（~Klass），重载的操作符（operator+），以及转换函数(operator void const *)。在Objective-C中，声明name包括，OC的方法，包括方法名和参数名。因为因为上面这些全部的实体，包括变量，函数，OC方法，C++构造析构函数，操作符之类都由Clang的标准NamedDecl类描述，所以就设计了DeclarationName类来高效的表达不同种类的name）  
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
