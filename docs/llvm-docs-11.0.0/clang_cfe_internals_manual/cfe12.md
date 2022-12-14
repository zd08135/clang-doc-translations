# 如何增加属性
属性是一些可以被附加到程序结构中的元数据。程序员可以在语义分析时，向编译器传递更多的信息。比如，属性可以改变程序结构代码生成，或者为静态分析提供更多的信息。本文档描述如何向Clang中添加一个自定义的属性，Clang中现有的属性可以参考[这里](https://clang.llvm.org/docs/AttributeReference.html)。
## 属性的基础信息
Clang中，属性在如下三个时机中处理：进行语法分析时，从语法属性转换成语义属性时，语义分析阶段处理该属性时。
属性的语法分析过程由不同的属性对应的句法决定，比如GNU, C++11, 微软各自风格的属性；也包括属性的表定义中所提供的信息。属性对象进行语法分析的最终结果，是一个ParsedAttr类的对象。这些转换后的属性链成一串，附加在声明上。除了关键字属性之外，属性的语法分析由Clang自动进行。当实现属性时，关键字的转换和对应ParsedAttr对象的创建必须手动处理。  
最终，在语法分析属性可以转换成语义分析属性时，会以Decl和ParsedAttr作为参数调用Sema::ProcessDeclAttributeList()方法。语法属性转换成语义属性这个流程依赖于属性的定义和语义要求。转换结果的是一个挂在该Decl上的语义属性对象，可以通过Decl::getAttr\<T\>()获取。
语义属性的结果也通过Attr.td中的属性定义管理。这个定义用于自动生成实现该属性功能的代码，比如clang::Attr的子类，用于语法分析的信息，部分属性的语义检查等。
## include/clang/Basic/Attr.td
为Clang添加新属性的第一步是在include/clang/Basic/Attr.td中添加其定义。这个表生成定义必须继承Attr（表生成，而非语义的）的定义，或者一个或多个其继承者。大部分属性都是继承自InheritableAttr类型，这个类型说明该属性可以被其关联的Decl的二次声明继承。InheritableParamAttr和InheritableAttr类似，不同点在于InheritableParamAttr是作用于参数的。如果某个属性是类型相关的，那么需要继承的类型是TypeAttr，并且也不会生成对应的AST内容。（注意，本文档不涵盖类型属性创建的内容）。一个属性继承IgnoredAttr的话，那么整个属性会被分析，但是只会生成一个忽略的属性诊断，这种场景可以应用于非Clang编译器的需求。  
这个定义包括几项内容，比如属性的语义名称，支持的拼写方式，需要的参数和其他内容。大多数Attr类的表生成类型的成员不需要其继承的定义像默认定义那样完善。不过每个属性至少得包含一个拼写列表，主语列表和文档列表。

### 拼写
所有的属性都要求指定一个拼写列表来说明该属性的拼写方式。比如，一个单独的语义的属性可能有一个关键字拼写，也可以是C++11规范的拼写，或者GNU扩展的拼写。如果属性是隐式创建的，那么也可以是空的拼写。下面几种拼写都是可以接受的：

| 拼写 | 描述 |  
| :-- | :-- |  
| GNU | GNU风格语法__attribute__((attr)) 和占位 |
| CXX11 | C++风格语法[[attr]]，被放在编译器指定的命名空间里。 |
| C2x | C风格语法[[attr]]，被放在编译器指定的命名空间里。 |
| Declspec | 微软风格语法__declspec(attr) |
| Keyword | 这个属性作为关键字进行拼写，需要特殊处理语法分析 |
| GCC | 指定两种拼写，第一种是GNU风格拼写，第二种是C++风格拼写（放在gnu命名空间中）只有GCC支持的属性才能使用这种拼写。 |
| Clang | 指定两种或者三种拼写，第一种是GNU风格拼写，第二种是C++风格拼写（放在clang命名空间中），第三种是可选的C风格拼写（放在clang命名空间中）。默认使用第三种。 |
| Pragma | 这个属性拼写是#pragma，需要预处理器进行特殊处理。如果这个属性只被Clang使用，那么其命名空间就得是clang。注意这个拼写不能对声明的属性使用。 |

### 主语

属性会关联一个或多个Decl主语。如果这个属性尝试附加到一个和其不关联的主语上，就会自动报一个诊断问题。这个诊断是警告还是错误，取决于这个属性的SubjectList是如何定义的，默认情况是警告。展示给用户的诊断信息由该SubjectList中的主语信息自动确定，当然也可以为该SubjectList指定一个自定义的诊断参数。这些因为主语列表错误而产生的诊断具有diag::warn_attribute_wrong_decl_type或者diag::err_attribute_wrong_decl_type类型，参数的枚举定义在include/clang/Sema/ParsedAttr.h之内。如果之前有一个被加入SubjectList的Decl节点，那么在utils/TableGen/ClangAttrEmitter.cpp中的自动决定诊断参数的逻辑也需要更新。  
默认情况下，SubjectList中的所有主语，要么是DeclNodes.td中的定义的一个Decl节点，要么是StmtNodes.td中定义的一个statement节点，不过也可以通过SubsetSubject创建更复杂的主语。每个这样的对象包含一个相关的base主语（必须是Decl或者Stmt节点，但是不能是SubsetSubject节点）以及一些用来判定某些属性是否属于该主语的自定义节点。比如，一个NonBitField SubsetSubject对象关联一个base主语FieldDecl，这个对象用来检查该FieldDecl对象是否是一个bit位。如果一个SubjectList中有一个SubsetSubject对象，那么就需要同时提供一个自定义的诊断参数。  
针对属性主语的自动化检查在HasCustomParsing != 1的情况下会自动执行。

### 文档
每个属性都必须有关联的文档。文档由对公的web服务的后台进程每日自动生成。一般情况下，一个属性添加了文档的话，该文档就会作为include/clang/Basic/AttrDocs.td中一个独立的定义存在。  
如果这个属性不是对外可用的，或者是没有可见拼写的隐式创建的，对应的文档列表可以指定一个Undocument对象。否则，属性的文档必须在AttrDocs.td中定义。
文档继承自Documentation表生成类型。所有继承的类型都必须制定一个文档目录，以及实际的文档内容本身。除此之外，还可以指定一个自定义的头部，如果没有的话就是用默认的头部。  
预定义的文档目录有4种：DocCatFunction指和类似函数的主语关联的属性，DocCatVariable指和类似变量的主语关联的属性，DocCatType对应类型属性，DocCatStmt对应语句属性。自定义的文档目录需要针对功能上相似的一组属性使用，方便提供针对这些属性的大纲类信息。比如，被消费的注解属性可以统一定义一种DocCatConsumed目录，这样可以在更高的层级上解释被消费的注解的具体含义。  
文档内容（不论是属性还是目录）使用reStructuredText (RST)语法撰写。  
写完属性的文档之后，需要在本地测试用服务器生成文档时是否有问题。本地测试需要使用新构建的clang-tblgen。执行下面的命令可以生成新的属性文档：
```shell
clang-tblgen -gen-attr-docs -I /path/to/clang/include /path/to/clang/include/clang/Basic/Attr.td -o /path/to/clang/docs/AttributeReference.rst
```
本地测试没有完成的话，不要提交针对AttributeReference.rst的修改。这个文件由服务器自动生成，针对该文件的修改会被覆盖。

### 参数
参数可以有选择地指定传给属性的参数列表。属性的参数可以是语法形式的，也可以是语义形式的。比如，如果Args的格式是[StringArgument<"Arg1">, IntArgument<"Arg2">]，那么__attribute__((myattribute("Hello", 3)))就是合法的使用；其在进行语法分析时需要2个参数，对应的Attr子类的构造函数中，针对该语义属性需要1个字符串和1个整形数作为参数。  
每个参数都有名字，以及指明该参数是否可选的标记位。参数相关的C++类型由参数的定义类型决定。如果已存在的参数类型不够用，可以创建新的类型，但是创建新类型时，需要修改utils/TableGen/ClangAttrEmitter.cpp来为新类型提供合适的支持。  

### 其他属性
Attr的定义还包括控制属性行为的其他成员。其中很多都是用于特殊目的的，这超出了本文的范围，不过还是可以简单说一下。  
如果属性语法分析后的形式更复杂，或者和语义分析的形式不同，那么就需要将HasCustomParsing标记位设成1，并且针对这种特殊case修改Parser::ParseGNUAttributeArgs()的代码。注意这个只针对GNU拼写的参数生效，使用__declsepc拼写的属性会忽略这个标记，并且由Parser::ParseMicrosoftDeclSpec处理。  
注意，该标记设置成1会不走常规的属性语义处理流程，所以需要额外实现来保证属性和合适的主语正常关联。  
如果这个属性在由模板声明进行实例化时不能被复制，那么要将Clone成员设置为0。默认情况下，所有的属性在模板实例化时都可以被复制。  
不需要生成AST节点时，将ASTNode成员设置成0，避免“污染”AST。注意，继承自TypeAttr和IgnoredAttr的类自动就不会生成AST节点。其他的属性则默认会生成AST节点。AST节点是属性的语义表示。  
LangOpts字段指定该属性的一系列语言选项。比如，CUDA相关的属性在LangOpts字段指定了[CUDA]信息，如果CUDA语言选项没有enable，那么就会抛出一个"属性被忽略"的警告诊断。因为语言选项不是表自动生成的节点，新的语言选项必须手动创建，通过LangOptions类指定其拼写。  
可以通过属性的拼写列表来生成针对该属性的自定义访问接口。比如，如果一个属性有2个拼写：Foo和Bar，就会创建这样的访问接口[Accessor<"isFoo", [GNU<"Foo">]>, Accessor<"isBar", [GNU<"Bar">]>]。这些接口会生成在属性的语义形式中，不接收参数，返回bool类型的值。  
不进行特殊语义处理的属性，需要将SemaHandler设置成0。注意，所有继承自IgnoredAttr的属性都不会有特殊的语义处理，其他的属性都默认假设其有语义处理。没有语义处理逻辑的属性不能赋值一个属性的Kind枚举值。  
"简单的"属性，也就是除了自动生成的部分之外，没有其他自定义语义处理流程的，需要将SimpleHandler设置成1。  
针对特定目标平台的属性，不同的目标平台也可以共享同样的拼写。比如，ARM和MSP430目标平台各自有一个GNU<"interrupt">属性，但是语法和语义的处理逻辑不同。为了支持这个特性，继承自TargetSpecificAttribute的属性需要指定一个ParseKind字段。这个字段在共享相同拼写的参数中要保持同样的值，并且和语法转换后的Kind枚举值对应。这就允许属性可以共享同一个语法属性的kind，而语义处理的类则各不相同。比如，这两个平台共享ParsedAttr这个相同的语法kind，但是却对应不同的属性：ARMInterruptAttr和MSP430InterruptAttr。  
默认情况下，属性的参数都是在已经计算过的上下文中转换的。如果需要在未计算的上下文中转换参数时，该属性的ParseArgumentsAsUnevaluated设置为1。时
如果希望属性的语义形式有附加的功能，AdditionalMembers字段可以指明那些会被按原样复制到语义属性类的对象，这些代码访问限制为public。  

## 样板代码
所有针对声明属性的语义处理代码都在lib/Sema/SemaDeclAttr.cpp中，一般都是从ProcessDeclAttribute()函数开始的。如果属性的SimpleHandler标记位为1，那么该属性的处理逻辑是自动生成的，开发者不需要做什么；否则（SimpleHandler != 1），就需要编写新的handleYourAttr()函数，并且放到switch语句中。注意不要直接在switch语句的case中去写实现逻辑。  
在属性定义没有特别指明的情况下，针对语法转换后属性的公共语义检查是自动处理的。公共语义检查包括诊断语法属性是否和对应的Decl节点关联，保证传递的参数个数满足要求的最小值等。  
如果属性添加附加的告警信息，可以在include/clang/Basic/DiagnosticGroups.td中，该属性的拼写之后定义一个DiagGroup，其中的"\_"要替换成"-"。如果诊断只有一个，那么直接在DiagnosticSemaKinds.td用InGroup<DiagGroup<"your-attribute">>方式定义也是可以的。  
所有针对新属性的语义诊断，包括自动生成的那些（比如主语和参数个数）都需要有对应的测试用例。  

## 语义处理
大部分的属性实现上都会对编译器有影响。比如，修改生成代码的方式，针对分析pass添加额外的语义检查等。添加属性的定义和转换成语义表示的逻辑之后，剩下的部分就是实现该属性需要的自定义逻辑。  
clang::Decl对象可使用hasAttr\<T\>的接口来查询该属性是否存在，也可以使用getAttr\<T\>来获取该属性语义表示的指针。

# 如何增加表达式或者语句
表达式和语句是编译器中最基础的构造之一，他们会和AST、语义分析、IR生成的多个部分都进行交互。所以，给Clang添加新的表达式或语句的kind时，要稍微注意一下。下面的列表详细说明了在引入新的表达式或语句时需要注意的点，以及保证新的表达式或语句可以在C系语言中都可以正常运作而需要遵守的一些范式。这里我们主要关注表达式，但是语句也是类似的。
1. 引入语法分析的动作。采用尾递归方式进行的语法分析是最容易理解的，但是有一些事情需要注意：
   - 尽可能多的记录代码位置信息。在后续产生大量的诊断，以及支持Clang在映射源码到AST映射时的不同特性时会用到。
   - 编写针对所有错误分析的测试用例，保证恢复是可行的。如果匹配到了分隔符（比如小括号(，方括号[等），在发现错误时，用Parser::BalancedDelimiterTracker可以提供比较优雅的诊断信息。
2. 在Sema中引入新的语义分析动作。语义分析主要涉及两个函数：ActOnXXX会由语法分析器直接调用，BuildXXX则会运行实际的语义分析逻辑，并最终生成AST节点。ActOnCXX只执行少量的逻辑（经常就是最小程度上将语法表示转成语义表示）是很平常的事情，但是划分成2个函数仍然是有必要的：C++模板实例化，会经常调用BuildXXX。在进行构建AST之前的语义分析时，以下几点需要处理：
   - 新的表达式很有可能涉及一些类型和子表达式。注意完整检查这些类型和子表达式的类型符合预期。在需要的地方加入隐式转换，保证所有的这些类型可以很精确地按照需要的方式串起来。编写大量的测试用例来检查不同错误下可以获得良好的诊断信息，以及表达式可使用各种不同形式的子表达式。
   - 对类型或者子表达式进行类型检查时，保证首先检查类型是否是独立的（通过Type::isDependentType()方法），或者子表达式的类型是否是独立的（通过Expr::isTypeDependent()方法）。只要其中一个返回true，就说明此时在模板中，没法执行太多的类型检查。这种情况很正常，新的AST节点需要处理这些情形。针对这一点，可以编写在模板中使用该表达式的用例，但是不要去实例化这些模板。
   - 针对子表达式，处理那些表现上不像正常表达式的怪异表达式时，注意调用Sema::CheckPlaceholderExpr()。然后，对需要子表达式有值并且该值需要被使用的地方，确定是否需要左值到右值的转换(Sema::DefaultLvalueConversions）或者常见的一元转换(Sema::UsualUnaryConversions)。
   - 此场景下（注意，指上面提到的“在构建AST之前的语义分析时”），BuildXXX函数只要返回ExprError()即可。这样就很好，而且应该不会影响测试。
3. 针对新的表达式引入AST节点。首先要做的是在include/Basic/StmtNodes.td中声明这个节点，并且在合适的include/AST/Expr*.h头文件中创建新的类。最好的做法是参考相似的表达式的类，然后下面几点需要注意：
   - 需要分配内存的话，就使用ASTContext分配器。不要直接调用底层的malloc或者new，在AST中也不要持有资源，因为AST的析构函数永远不会调用。
   - 保证getSourceRange()函数可以准确覆盖表达式的代码范围，这在诊断和IDE支持时很有必要。
   - 保证children()方法可以访问到所有的子表达式，这在很多特性中有用（比如IDE支持，C++可变参数模板）。如果表达式有子类型，那么需要能通过RecursiveASTVisitor访问到这些子类型。
   - 支持表达式的打印（StmtPrinter.cpp)
   - 支持AST的性能分析（StmtProfile.cpp）。注意区分表达式实例中位置无关的字符，否则可能导致在匹配模板声明时出现难以诊断的转换失败。
   - 支持AST的序列化（ASTReaderStmt.cpp, ASTWriterStmt.cpp）
4. 让语义分析可以构建AST节点。这个时候就可以调用Sema::BuildXXX方法来实际生成AST了。这个时候需要注意的事情：
   - 如果表达式可以构造一个新的C++类，或者返回一个新的Object-C对象，保证更新并为新创建的AST节点调用Sema::MaybeBindToTemporary，这样这个新的对象可以被恰当的析构。比较简单的测试方式是返回一个析构函数为private的类，语义分析在尝试调用析构函数时会标记错误。
   - 通过clang -cc1 -ast-print命令打印并检查AST，保证关于AST如何打印的所有重要信息都已经被完善处理了。
   - 通过clang -cc1 -ast-dump验证AST中的所有类型都按照需要的方式进行组织了。注意，AST的客户端们不需要“思考”必须可以直接了解到实际发生的情况。比如，所有可能出现的隐式转换在AST中都必须显式展示出来。
   - 测试新表达式作为被熟知的表达式的子表达式的情况。比如，这个表达式可以作为函数参数吗？可以用在条件运算符（注意，?:）中吗？
5. 让代码生成可以从AST节点生成IR。这一步是需要了解LLVM IR的第一个场景（也是唯一的场景）。以下几点要注意：
   - 表达式的代码生成，根据其生成的结果，可以分成scalar/aggregate/complex（注意，scalar表示纯数值，比如bool/int/float等；aggregate指复合类型，比如struct/class；complex指更复杂的类型，比如带指针的struct/class）代码以及左值/右值等不同路径。部分情况下，这里需要对代码小心处理以避免重复。
   - CodeGenFunction类包含ConvertType和ConvertTypeForMem函数将Clang的类型（clang::TypeXXX或者clang::QualType）转换成LLVM的类型。前者用于值，后者用于内存位置：可以用C++的bool类型来测试。如果出现了必须使用LLVM的按位转换才能将子表达式转换成所期望的类型，就赶紧停下，然后去修复AST的语义分析，去掉这些按位转换。
   - CodeGenFunction类包含若干辅助类函数来简化特定操作，比如生成左值赋给右值的代码，用给定值初始化一块内存区域。建议使用这类辅助函数，而不是直接执行load/store，因为这些函数处理了一些特殊内容（比如异常）
   - 如果表达式在出现异常时需要有一些特殊操作，参考CodeGenFunction类中的push*Cleanup函数加入清理逻辑。开发者应该不需要直接关注如何处理异常。
   - IR生成时，进行测试十分重要。使用clang -cc1 -emit-llvm和FileCheck类来验证是否生成了正确的IR。
6. 在模板实例化时，仔细处理AST节点，这只需要一些很简单的代码：
   - 保证表达式的构造器可以正常计算类型独立（即让表达式的类型可以随着实例化类型的不同而不同）、值独立（即表达式生成的常量的类型随着实例化类型的不同而不同）、实例独立（即表达式中出现的模板参数）的标记位，以及表达式是否包含了打包的参数（针对可变参数的模板）。常见情况下，计算这些标记只需要将不同类型和子表达式结合起来就行了。
   - 给Sema中的TreeTransform类添加TransformXXX和RebuildXXX函数。TransformXXX可以递归转换表达式中的所有的类型和子表达式，通过使用getDerived().TransformYYY。如果所有的子表达式和类型都可以正确转换无报错，那么后面就会调用RebuildXXX函数。这个函数会按顺序调用getSema().BuildXXX来执行语义分析并构建表达式。
   - 测试模板实例化时，编写用例来保证在不同类型下，针对类型独立的表达式和依赖的类型（来自步骤#2）做类型检查，并且实例化这些模板都可以正确运行。部分类型需要类型检查，部分不需要。也要注意测试各个用例的错误消息。
7. 针对其他特性的“额外”工作。处理这些额外内容可以更好帮助表达式与Clang的集成。
   - 在SemaCodeComplete.cpp添加代码补全逻辑。
   - 如果表达式有新的类型，或者除了子表达式之外的其他有趣特性，可以扩展libclang的CursorVisitor类来提供对表达式更好的可视化，这对多个IDE特性有帮助，比如语法高亮，交叉引用等。可以使用c-index-test辅助程序来测试表达式的这些特性。


---------------------    

[原文](https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html#how-to-change-clang)