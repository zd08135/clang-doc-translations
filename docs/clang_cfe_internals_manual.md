
# 基本说明

## 源码地址

参考llvm github:  
https://github.com/llvm/llvm-project.git  
https://gitee.com/mirrors/LLVM.git  （github地址的国内镜像，每日同步）  

## 版本选择

基于clang11版本文档翻译  
https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html

选择11.0版本的代码，具体版本如下：

```
commit 1fdec59bffc11ae37eb51a1b9869f0696bfd5312 (HEAD, tag: llvmorg-11.1.0-rc3, tag: llvmorg-11.1.0, origin/release/11.x)
Author: Andi-Bogdan Postelnicu <abpostelnicu@me.com>
Date:   Wed Feb 3 17:38:49 2021 +0000

    [lldb] Fix fallout caused by D89156 on 11.0.1 for MacOS

    Fix fallout caused by D89156 on 11.0.1 for MacOS

    Differential Revision: https://reviews.llvm.org/D95683
```

TODO: **未来可能会按照clang版本形式，将本文档也划分成不同版本**

## 平台

本文的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）

---------------
# ---以下为正文---

# 介绍

本文档描述了clang前端中，一些重要API以及内部设计，旨在让读者可以既可以掌握一些高层次的信息，也可以了解背后的一些设计思路。
本文的更针对探索clang内部原理的读者，而不是一般的使用者。下面的描述根据不同的库进行组织，但是并不会描述客户端如何使用它们。

# LLVM支持库

LLVM支持库libSupport提供了一些底层库和数据结构，包括命令行处理、不同的container以及用于文件系统访问的系统抽象层。

# Clang的基础库

这一部分库的名字可能要起得更好一点。这些“基础”库包括：追踪、操作源码buffer和包含的位置信息、诊断、符号、目标平台抽象、以及语言子集的偏基础类的util逻辑。  
部分架构只针对C语言生效（比如TargetInfo），其他部分（比如SourceLocation, SourceManager, Diagnostics,
FileManager）可以用于非C的其他语言。可能未来会引入一个新的库、把这些通用的类移走、或者引入新的方案。  
下面会根据依赖关系，按顺序描述基础库的各个类。

## 诊断子系统

Clang诊断子系统是编译器和用户交互的重要部分。诊断主要指代码错误，或者不太可信的情况下，编译器生成的警告和错误。在Clang中，每个诊断信息包括：
唯一id、对应的英文翻译、sourcelocation信息（用来展示^），严重级别（警告或者错误）。除此之外，还包括可选的一系列参数和代码段信息。  
本节中，我们会看到一些Clang产生的诊断的例子，当然诊断信息可以根据DiagnosticConsumer接口的不同实现从而有各种不同的渲染方式。一个可读的例子如下：

```
t.c:38:15: error: invalid operands to binary expression ('int *' and '_Complex float')
P = (P-42) + Gamma*4;
    ~~~~~~ ^ ~~~~~~~
```
上面这个例子中，可以看到英文翻译、严重级别，源码位置（^号和文件/行/列信息），诊断的参数、代码片段。当然你也知道内部还有个id（笑）  
让这些内容产生需要若干步骤，涉及到很多移动的分片。本节中会描述这些步骤、分片，也会说明增加新诊断信息的一些最佳实践。  

### The Diagnostic*Kinds.td files
根据需要使用的库，在clang/base/Diagnostic*Kinds.td相应文件中增加一个入口点就可以创建诊断。tblgen会根据文件创建唯一id，严重级别，英文翻译，格式化字符串等。  
这个唯一id在命名上也包含一些信息。有的id以err_，warn_，ext_开头，将严重级别列入到id里面。这些严重级别的枚举与产生相应诊断的C++代码关联，所以这个级别简化有一点意义。   
诊断的严重级别包括这些：{NOTE, REMARK, WARNING, EXTENSION, EXTWARN, ERROR}。ERROR这个诊断说明，代码在任何情况下都是不能被接受的；如果产生了一个error诊断，代码的AST可能都没有完全构建好。EXTENSION 和 EXTWARN 用于Clang可以兼容的语言扩展，也就是说，Clang仍然可以构建AST，但是诊断会提示说代码不是可移植的；EXTENSION 和 EXTWARN 的区别在于，默认情况下，前者是被忽略的，而后者会提示警告。WARNING说明，代码在语法规则下是合法的，但是可能有些地方会有二义性。REMARK则说明相应的代码没有产生二义性。NOTE的话，一般是对之前的诊断做补充（没有实际意义）。  
上面这些级别可以映射到诊断子系统的实际输出的levels信息（Diagnostic::Level 枚举, 包括Ignored, Note, Remark, Warning, Error, Fatal）。Clang内部支持一种粗粒度的映射机制，可以让差不多所有的严重级别都可以和level对应上。不能映射的只有NOTES——其级别依赖前面的诊断——以及ERROR，只能映射到Fatal（换句话说，没法把ERROR级别映射到warning level）。  
诊断映射的应用场景很多。比如，-pedantic这个选项会使得EXTENSION映射到Warning, 如果指定了-pedantic-errors选项，EXTENSION就是Error了。这种机制可以实现类似-Wunused_macros, -Wundef 这样的选项。  
映射Fatal一般只能用于过于严重，从而导致错误恢复机制也无法恢复的情况（然后带来成吨的错误）。比如说，#include文件失败。  

### 格式化字符串

用于诊断的格式化字符串看起来简单，但是能力却很强大。格式化字符串主要的形式是一个英文字符串，包含了一些参数格式标记。比如
```
"binary integer literals are an extension"
"format string contains '\\0' within the string body"
"more '%%' conversions than data arguments"
"invalid operands to binary expression (%0 and %1)"
"overloaded '%0' must be a %select{unary|binary|unary or binary}2 operator"
    " (has %1 parameter%s1)"
```
上面这些示例中，展示了格式化字符串中一些重要的特点。除了%之外的所有ascii字符都可以以原始格式放到诊断字符串里，不过注意这些是C字符串，所以要注意0字符转义问题（如示例2）。如果需要使用%，就要用转义：%%（示例3）。Clang使用“%...[digit]”这种序列指定参数的位置和格式化方式。  
诊断的参数通过带编号的方式引用：%0-%9，具体编号取决于生成诊断的C++代码。超过10个参数的话，可能某些地方得再考虑一下（笑）。和printf不同，参数在字符串的位置，可以和传递的顺序不同；比如可以通过"%1 %0"的方式交换2个参数。%和数字之外的文本用于格式化指示；如果没有这些指示，参数就只会变成一个单独的字符串。  
制定字符串一些最佳实践如下：
- 短一点。不要超过DiagnosticKinds.td的80长度限制，这样不会导致输出时丢失，也可以让你考虑怎么通过诊断信息表达出更重要的点。
- 多利用位置信息。用户可以看到代码的行和具体的位置，所以不用在字符串中告知比如类似第4个参数有问题之类的。
- 不要大写，结尾不要带.（英文句号）
- 如果要引用什么东西，用单引号  
诊断不要用随机的字符串做参数：比如格式化字符串是“you have a problem with %0” 然后传参是“your argument”或者 “your return value” ；这么做不利于翻译诊断文本到其他语言（因为可能文本被翻译了，但是参数仍然是英文的）；C/C++的关键字，以及操作符这类的情况除外，不过也要注意pointer或者reference不是关键字。换句话说，你可以用代码中出现的所有的东西（变量名、类型、标记等）。使用select方法可以以很本地化的方式达到这样的目的，见下文。

### 格式化诊断参数
参数是完全在内部定义的，来自不同的类别：整数、类型、名字、随机串等。根据参数类别不同，格式化方式也不同。这里给一下DiagnosticConsumer（#没理解）
下面是Clang支持的参数格式化方式：


"s"格式  
Example: "requires %1 parameter%s1"  
Class: Integers  
Description: 这是个简单的整数格式化方式，主要用于生成英文的诊断信息。如果这个整数是1，什么都不输出；否则输出1。 这种方式可以让诊断内容更符合一些简单的语法，不用生成"requires %1 parameter(s)"这种粗放的表达。

“select” format  
Example: "must be a %select{unary|binary|unary or binary}2 operator"  
Class: Integers  Description: 这个格式可以把几个相关的诊断合并成1个，不需要把这些诊断的diff用单独的参数替代。不同于指定参数为字符串，这个诊断输入整数参数，格式化字符串根据参数选择对应的选项。本例中，%2参数必须是[0..2]范围的整数。如果%2是0，那么这里就是unary，1的话就是binary，2的话就是“unary or binary”。这使得翻译成其他语言时，可以根据语法填入更有意义的词汇或者整条短语，而不是通过文本的操作处理。select格式的string会在内部进行格式化。

“plural” format  
Example: "you have %1 %plural{1:mouse|:mice}1 connected to your computer"  
Class: Integers  
Description: 	这个格式适用于比较复杂的英文的复数形式。这个格式的设计目的是处理对复数格式有一定要求的语言，比如波罗的海一些国家的语言。这个参数包含一系列的<expression:form>的键值对，通过:分隔。从左到右第一个满足expression为真的，其form作为结果输出。 	expression可以没有任何内容，这种情况下永远为真，比如上面的示例（中的mice）。除此之外，这个是若干个数字的condition组成的序列，condition之间由,分隔。condition之间是或的关系，满足任意一个condition就满足整个expression。每个数字condition有下面几种形式： 
- 单个数字：参数和该数字相等时满足condition，示例"%plural{1:mouse|:mice}4" 
- 区间。由[]括起来的闭区间，参数在该区间时满足condition，示例"%plural{0:none|1:one|[2,5]:some|:many}2" 
- 取模。取模符号% + 数字 + 等于号 + 数字/范围。参数取模计算后满足等于数字/在区间内则满足condition，示例"%plural{%100=0:even hundred|%100=[1,50]:lower half|:everything else}1" 

这个格式的Parser很严格。只要有语法错误，即便多了个空格，都会导致parse失败，不论什么expression都无法匹配。

“ordinal” format  
Example: "ambiguity in %ordinal0 argument"  
Class: Integers  
Description: 这个格式把数字转换成“序数词”。1->1st，3->3rd，只支持大于1的整数。 这个格式目前是硬编码的英文序数词。

“objcclass” format  
Example: "method %objcclass0 not found"  
Class: DeclarationName  
Description: （object-c专用，后面翻译） This is a simple formatter that indicates the DeclarationName corresponds to an Objective-C class method selector. As such, it prints the selector with a leading “+”.

“objcinstance” format  
Example: "method %objcinstance0 not found"  
Class: DeclarationName  
Description: （object-c专用，后面翻译） This is a simple formatter that indicates the DeclarationName corresponds to an Objective-C instance method selector. As such, it prints the selector with a leading “-“.

“q” format  
Example: "candidate found by name lookup is %q0"  
Class: NamedDecl *  
Description: 这个格式符号表示输出该声明的完全限定名称，比如说，会输出std::vector而不是vector

### 产生诊断
在Diagnostic*Kinds.td文件中创建入口点之后，你需要编写代码来检测相应情况并且生成诊断。Clang中的几个组件（例如preprocessor, Sema等）提供了一个辅助函数"Diag"，这个函数会创建诊断并且传入参数、代码范围以及诊断相关的其他信息。  
比如，下面这段代码产生了一个二元表达式相关的错误诊断。  
```
if (various things that are bad)
  Diag(Loc, diag::err_typecheck_invalid_operands)
    << lex->getType() << rex->getType()
    << lex->getSourceRange() << rex->getSourceRange();
```
这里展示了Diag方法的使用方式：接受一个location（SourceLocation对象）以及诊断的枚举值（来自Diagnostic*Kinds.td文件）。如果这个诊断需要参数，那么这些参数通过<<操作符指定：第一个参数就是%0，第二个是%1，以此类推。这个诊断接口支持指定多种类型的参数，包括整数的：int, unsigned int。字符串的const char*和std::string，用于名称的DeclarationName 和const IdentifierInfo * ，用于类型的QualType，等等。SourceRange对象也可以通过<<指定，不过并没有特定的顺序要求。  
正如上面所示，添加诊断、生成诊断的流程很简洁直接。最困难的地方在于怎么准确的描述诊断要表达的内容，选择合适的词汇，并且提供正确的信息。好消息是，产生该诊断的调用，应该和诊断信息的格式化方式、以及渲染所用的语言（展示给用户的诊断自然语言）必须是完全独立的。

### “建议修改”提示
有些情形下，很明显能看出做一些小的修改就可以修正问题，编译器会生成相应的（建议修改）诊断。比如，语句后缺少分号；或者使用很容易被更现代的形式替代的废弃的语法。在这些情形下，Clang在生成诊断并且优雅恢复方面做了很多工作。  
不过呢，对于修复方式很明显的情况，诊断可以直接表达成描述如何修改代码来修复问题的提示（引用方式是“建议修改”提示）。比如，添加缺失的分号或者用更好的方式重写废弃的结构。下面是一个C++前端的例子，用来警告右移操作符的含义在C++98与C++11中有变化。  
```
test.cpp:3:7: warning: use of right-shift operator ('>>') in template argument
              will require parentheses in C++11
A<100 >> 2> *a;
       ^
  (       )
```
上文中的建议修改提示就是需要加上小括号，并且准确的指出了需要插入小括号的代码的位置。这个提示本身以一种抽象的方式描述了需要做的修改，这个方式是在^号下面加了一行，通过诊断的文本输出“插入”的行为。其他的诊断客户端（这里指会调用诊断接口的程序）可能会选择不同的方式来展示这个代码（比如说内嵌标记），甚至直接帮用户自动改掉。  
针对错误和警告的建议修改提示需要遵循这些规则：
- 应用建议修改提示的方式是，将-Xclang -fixit参数传递给driver，所以这些建议只能在非常匹配用户的期望的时候才能使用。
- 如果应用了建议修改提示，那么Clang必须能从错误中恢复。
- 针对警告的建议修改提示，不能改变代码的逻辑。不过提示可以用来明确用户的意图，比如建议在操作符优先级不太明显区分的情况下加上括号。

如果某个建议不能遵从上面的规则，那么就把这个建议改成针对NOTE了，针对note的提示不会自动应用。

建议修改提示，通过FixItHint类进行描述；类对应的实例也需要和高亮代码段、参数一样，通过<<操作符传给诊断。创建一个提示对象有如下三个构造器：
- FixItHint::CreateInsertion(Loc, Code)  
  提示内容：将指定的参数Code插入到Loc的对应代码位置前面。
- FixItHint::CreateRemoval(Range)  
  提示内容：Range所指定的代码段建议删除
- FixItHint::CreateReplacement(Range, Code)  
  提示内容：Range所指定的代码段建议删除，并且由Code对应的字符串替代

### DiagnosticConsumer接口    
代码根据参数和其余的相关信息生成了诊断之后，会提交给Clang处理。前文描述，诊断机制会执行一些过滤，将严重级别映射到诊断level，然后（如果诊断没有映射成ignored的情况下）以诊断信息为参数，调用DiagnosticConsumer接口的某个实现。    
实现接口的方式多种多样。比如，最普通的Clang的DiagnosticConsumer实现(类名是TextDiagnosticPrinter），就是把参数根据不同的格式化规则转成string，然后输出文件/行数/列数，该行的代码，代码段，以及^符号。当然这种行为并不是要求的。    
另一个 DiagnosticConsumer 的实现是 TextDiagnosticBuffer 类，当Clang使用了-verify参数的时候会被调用。这个实现只会捕获并且记录诊断，然后比较生成的诊断信息和某个期望的列表是否一致。关于-verify的详细说明请参考Clang API文档的VerifyDiagnosticConsumer类。  
这个接口还有很多其他的实现，所以我们更希望诊断可以接受表达能力比较强的结构化信息作为参数。比如，可以通过HTML输出来给declaration的符号名加上定位链接。也可以通过GUI的方式，点击展开typedef；实现这种方式时，需要将更重要、信息量更大的类型信息，而不是单纯的字符串作为参数传递给这个接口。  

### Clang增加多语言翻译
目前还不行。诊断的字符串需要用UTF-8字符集编码，调用的客户端在需要的情况下可以将翻译相应的。翻译的时候需要整个替换掉诊断中的格式化字符串。

## SourceLocation和SourceManager类
SourceLocation类用来描述代码在程序中的位置。重点信息如下：
- sizeof(SourceLocation)越小越好，因为可能有大量的SourceLocation对象会嵌入AST节点内部，以及节点间传递。目前是32个bit
- SourceLocation是一个简单类型值的对象（没有指针，依赖等复杂结构），这样就可以被高效率的拷贝。
- SourceLocation可以描述任何一个输入文件的任何一个字节。包括在符号中间，空格，三字节的字符（比如utf8文本）等
- 在处理相应位置的代码时，SourceLocation要标记当前的#include栈为active。比如说，如果某个SourceLocation对象对应了一个token，那么当词法分析解析这个token的时候，所有的active的#include栈集合都需要记录在这个SourceLocation对象中。这样就可以在诊断时输出#include栈了。
- SourceLocation有能力描述宏的展开，不论是代码中的原始文本，还是最终的实例化内容。

在实践中，SourceLocation常常和SourceManager配合来描述某个代码位置的两方面信息：拼写位置，展开位置。对于大部分的符号来说，这两个一致。不过需要展开宏（或者_pragma指令定义的符号）的地方，它们就分别用来描述这个符号本身的位置以及使用的位置（宏展开或者_pragma指令位置）

## SourceRange和CharSourceRange
Clang中，大部分的代码段都可以通过[first, last]区间表达，first和last分别指向代码段开头与结尾的符号。比如下面这段语句的SourceRange
```
x = foo + bar;
^first    ^last
```
为了从这种表达转成基于字符的表达，last的位置需要调整成为指向token的结尾，调整可以通过Lexer::MeasureTokenLength() 或者 Lexer::getLocForEndOfToken()方法实现。极少情况下，我们需要字符级别的代码范围，这个时候可使用CharSourceRange类。

# 驱动库

clang驱动器和相应的库见这里

# 预编译头文件
Clang支持预编译头文件（precompiled headers, [PCH](https://releases.llvm.org/11.0.0/tools/clang/docs/PCHInternals.html)，这些头文件使用[LLVM bitstream format](https://llvm.org/docs/BitCodeFormat.html)格式对Clang内部的数据结构做了编码。

# 编译前端库
编译前端库主要提供了基于Clang库构建工具（二次开发）的能力，比如一些输出诊断的方法。

## Token类
Token类用于表示一个单独的语法分析符号。Token对象的主要使用者为词法分析器、预处理器和语法分析器，但是生命周期不会高于他们（比方说，在AST中就没有Token对象了）  
运行语法分析器时，Token对象大部分情况都是在栈上分配（或者其他读写访问效率高的地方），不过也偶尔会分配到独立的缓冲区里。比如，宏定义在存储上也是按照一个Token对象列表处理的，C++编译前端会周期性的将宏放进缓存来做初步的语法分析，以及一些需要预先查看（look ahead）的片段。正因为这些原因，Token的大小必须要考虑。在32位系统中，目前sizeof(Token)是16字节。  
Token有两种表现形式：annotation Token和普通Token。普通Token就是进行词法分析时解析到的Token对象，annotation则由语法分析器生成，包含了语法相关的信息。普通Token包含这些信息：  
- SourceLocation —— 指明Token起始的代码位置
- length —— 这个长度是保存在SourceBuffer中的token的长度。这个长度包含了三元运算符，末尾的换行符之类的，这些符号在后面的编译流程中都会被忽略掉。通过指向原始buffer中的指针，可以以完全准确的获取代码中的原始拼写内容。
- IdentifierInfo — 如果一个token表现为标识符的形式，并且在词法解析这个token时启用了标识符检索（也就是说，词法解析器并不是只处理原始内容），那么IdentifierInfo就包含了指向这个标识符的唯一hash值。由于检索在关键字标识之前，这个字段针对"for"这样的关键字也会被设置。
- TokenKind — 这个字段表明由词法分析器确定的符号种类。种类包括tok::starequal （针对“*=”操作符）, tok::ampamp（针对“&&” 符号），以及和关键字对应的值(比如tok::kw_for) . 注意一些符号可能有多种拼写，比如C++支持“操作符关键字”，“and” 等价于 “&&” 操作符。这种情形下，这个字段就设置成了tok::ampamp, 这样方便了语法解析器，不用处理&&和and两种形式。如果（两者等价但是又）需要考虑具体哪种形式的场景 (比如预处理 “stringize”操作符），其拼写表明了最初的形式。
- Flags — 目前有4个标记位处理每个token的最基本内容:
  1. StartOfLine — 符号在输入源码中第一次出现的行号。
  2. LeadingSpace — 在token最前面，或者宏展开时被传递的最前的空格字符。这个标记的定义与stringizing预处理规则紧密关联。
  3. DisableExpand — 这个标记在预处理器内部使用，表示这个符号不会进行宏展开，防止后续被选择参与宏展开。
  4. NeedsCleaning —  如果符号的原始拼写包含三元组或转义换行符，则设置此标志。由于这种情况并不常见，因此许多代码片段可以在不需要清理的符号上快速扫过。（#没理解）  

普通符号的一个有趣（且有些不寻常）的方面是，它们不包含有关词法值的任何语义信息。例如，如果该标记是 pp 数字标记，则我们不表示被词法化的数字的值（这留给后面的代码段来决定）。此外，词法分析库没有 typedef 名称与变量名称的概念：两者都作为标识符返回，后面由语法解析器决定特定标识符是 typedef 还是变量（需要来自作用域和其他信息帮助追踪）。解析器可以通过将预处理器返回的标记替换为"注释符号"来执行此转换。

## 注释符号
注释符号是由语法分析器合成并注入预处理器的符号流（替换现有符号）的符号，用于记录语法分析器发现的语法信息。比如说，如果发现“foo”是一个类型，那么“foo” tok::identifier符号就被替换成tok::annot_typename。这个可以带来以下几个好处：1) 语法分析时，很容易把C++中限定的符号名（比如“foo::bar::baz<42>::t”）当成一个单一的符号处理。2) 如果语法分析过程有回溯，那么再次分析时，不需要重新分析判断符号是不是变量、类型、模板等等。  
注释符号由语法分析器生成，并且会被再次注入到预处理器的符号流里面（会替代一些已经存在的符号）。因为注释符号只存在于已处理完毕预处理阶段的符号中，所以不需要追踪只有预处理才需要的标记，比如说“本行开头”之类的。另外，一个注释符号可以“覆盖”一个预处理符号序列（比如：a::b::c是5个预处理符号），所以，注释符号的字段内容和普通符号的字段有差异（当然字段内容是复用的）：  
- SourceLocation “Location”注释符号的SourceLocation指明所替换的符号序列的最前面一个。针对上面的例子来说，就是"a"
- SourceLocation “AnnotationEndLoc”指明所替换的符号序列的最后一个。针对上面的例子来说，就是"c"
- void* “AnnotationValue”包含了一个信息不明确的数据，从Sema中获取用于语法分析。语法分析器会只保存来自Sema的信息，并根据注释符号的种类进行后续的解释操作。
- TokenKind “Kind”符号的种类，不同种类描述如下。

目前，注释符号的种类有如下三个。
1. tok::annot_typename: 这个注释符号代表一个已解析的基本确认合法的类型名。 对应的AnnotationValue字段的内容是由Sema::getTypeName()返回的QualType信息，有可能也携带着相应的source location信息。  
2. tok::annot_cxxscope 这个符号代表一个C++的作用域标识，比如A::B::，对应C++语法规范中的::和:: [opt] nested-name-specifier。对应的AnnotationValue字段的内容是一个NestedNameSpecifier*类型的指针，由Sema::ActOnCXXGlobalScopeSpecifier 和Sema::ActOnCXXNestedNameSpecifier 回调获得。  
3. tok::annot_template_id 这个符号代表一个C++的模板id，比如foo<int, 4>，foo是模板的名字。对应的AnnotationValue字段的内容是一个动态分配的TemplateIdAnnotation对象。根据上下文不同，一个描述类型的模板id在分析后会变成一个typename注释符号（如果关注的内容是类型本身，比如一个类型定义）或者保持现状，仍然是一个模板id注释符号（如果关注的内容是在对应的代码位置，比如一个声明）。模板id注释符号可以被语法分析器“升级”成一个typename注释符号。 

如上所述，注释符号并非由预处理器返回，但是需要遵循语法分析器的格式要求。这意味着，语法分析器必须了解什么时候注释需要出现并且以合适的格式生成之。这某种程度上和语法分析器处理C99规范：Translation Phase 6 of C99: String Concatenation (see C99 5.1.1.2)（C99 5.1.1.2 第6条内容： Adjacent string literal tokens are concatenated，相邻的字符串常量token需要连到一起）的方式类似。处理字符串连接的时候，预处理器就区分tok::string_literal和tok::wide_string_literal两种符号，然后语法分析器将后面跟着的一串语法格式符合字符串常量的全部纳入解析。  
为了达到这一目标，只要parser解析到需要tok::identifier或者tok::coloncolon的时候，它就调用TryAnnotateTypeOrScopeToken或者 TryAnnotateCXXScopeToken来生成这个token。这些方法会尽可能在允许的时候，生成注释符号并替代当前符号。如果当前的符号不能用于生成注释符号，就保留为一个标识符或者::符号。  

## Lexer类
Lexer类提供了从源码buffer中进行词法分析获取符号并确认其含义的机制。Lexer的实现很复杂，因为它必须处理并没有进行拼写消除的原始buffer（在使用了拼写消除的基础上可以获得比较好的性能），但是反过来需要特别小心的编码，同时也要在性能上满足一定的标准（比如，处理注释的代码在x86和powerpc主机上就使用了向量指令）
Lexer包含若干个有趣的feature。  
- Lexer可以在原始模式下操作。原始模式中，可以采用若干机制来快速分析一个文件（比如，忽略标识符的查找、忽略预处理符号、特殊处理EOF等）。这种模式可以用来分析比如#if 0包含的语句块（快速跳过）
- Lexer可以捕获并处理注释。这个能力在使用-C选项的预处理模式中使用，预处理模式会输入注释内容，并由来获取哪些需要报错的注释信息。
- lexer可以工作在ParsingFilename模式，这个模式主要是预处理时，处理#include指令时使用。这个模式处理时会将<的内容返回一个string，而不是这个文件中的代码对应的token
- 分析（#之后的）预处理指令时，Lexer会进入ParsingPreprocessorDirective 模式，这模式会让分析器在处理换行时返回EOD。
- Lexer会使用LangOptions来设置是否开启三字符解析，是否识别C++和Object-C的关键字等等。

> 三字符：一些语言的键盘无法正确输入某些符号，则输入三字符并在解析时替换成该符号。参考：https://en.wikipedia.org/wiki/Digraphs_and_trigraphs.

## TokenLexer类
TokenLexer类是一个符号的provider，可以从来自其他地方的token中返回一些token。
典型应用包括：1) 从宏的展开中返回符号。2) 从一个比较随意的符号buffer中返回符号，这个通过_Pragma使用，主要用于C++语法解析时，防止无法停止的前探。

## MultipleIncludeOpt类
这个类实现一个简单的小状态机来识别标准的#ifndef XX / #define的习惯用法，这个用法主要用来防止头文件的重复#include。如果一个buffer用了这个惯用法，并且后面跟着#include指令，预处理器就可以很简单地检查这个标记是否定义。如果已经定义了，预处理器就会整个忽略include这个头文件。

# 语法分析库
这个库包含了一个递归下降的语法分析器，从预处理器中获取符号并通知分析流程的客户端。
历史上，分析器以前会调用一个抽象的Action接口，其定义了分析事件的一些virtual方法，比如ActOnBinOp。Clang加入C++支持之后，分析器就不在支持通用的Action客户端，而是只与Sema Library交互。不过，分析器仍然访问AST对象，但只能通过不明确的ExprResult和StmtResult类型访问。只有Sema才能通过这些wrapper来看到AST节点的实际内容。

# AST库
## 设计哲学
### 不变性
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

### 忠实性
AST会提供初始源代码的一个忠实表达。尽量只会用AST内部的或者再次构建信息来进行Refactor。这就要求AST表达不能解语法糖，也不能因为更清楚的表达而对代码进行解wrap。  
例如，CXXForRangeStmt 直接表达成一个range方式的语句，也包含range和迭代器相关的声明。但是不包含解语法糖之后的for语句。  
一些AST节点（比如ParenExpr）只包含语法信息，另一些（比如ImplicitCasrExpr）只包含语义信息；但是绝大多数的节点都是同时包含语法和语义信息。继承就是用来表达语法不同（但是相关）而语义相同的节点。  

### Type类和子类
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

### 公认类型
每个Type类都有一个公认类型指针。针对最简单的，不包含typedef的类型（比如int, int*, int\*\*等），这个指针就指向其自身。针对含有typedef信息的类型（比如上面例子的"foo","foo*","foo\*\*","bar"），公认类型指针指向的是与其结构一致的，不包含typedef信息的类型（比如，上面几个类型的指针各自指向：“int”, “int*”, “int**”, and “int*”）。  
这个设计可以使得访问类型信息时有常数的时间复杂度（只需解引用指针即可）。比如，我们可以很容易通过解引用+指针比较的方式，判定foo\*和bar为同一类型（都指向最普通的int\*类型)。  
公认类型也带来一些复杂性，需要小心处理。一般情况下，isa/cast/dyn_cast等操作符是不应该在检查AST的代码中出现的。比如，类型检查需要保证\*操作符的操作数，一定是指针类型。那么，这就没法正确地检查这样的表达式“isa<PointerType>(SubExpr->getType())"，因为如果SubExpr->getType()是一个typedef的类型，那么这个isa的推断就会出错。  
这个问题的解决方案是，在Type类中提供一个helper方法来检查其属性。本例中，使用SubExpr->getType()->isPointerType()来进行检查应该是正确的。如果其公认类型是一个指针，那么这个方法就会返回true，唯一需要注意的地方是不要使用isa/cast/dyn_cast这些操作符。  
第二个问题是，如何访问这个指针对应的类型。从上面的例子继续，\*操作的结果类型，必然是该表达式所指向的类型（比如，定义bar vx, \*vx的类型，就是foo，就是int）。为了找出这个类型，我们需要找到可以最佳捕获这个typedef信息的PointerType的实例。如果表达式本身的类型就是字面上的PointerType，那么就可以直接返回类型；否则我们必须沿着typedef信息挖下去。比如，若一个子表达式的类型是foo\*，那么我们就返回这个类型。如果类型是bar，我们希望返回的是foo\*（但是不是int\*）。为了达到这一目的，Type类提供了getAsPointerType()方法来检查类型本身是不是指针，如果是的话，就直接返回；否则会找一个最佳匹配的；如果不能匹配就返回空指针。  
这个结构有一点不是很清楚，需要好好的研究下才能明白。  

## QualType类
QualType类是平凡的值类型，特点是小，一般通过值传递，且查找起来很高效。其思想为保存类型本身，以及类型限定符（比如const, volatile, restrict或者根据语言扩展的其他限定符）概念上，QualType包含由Type*指针和指明限定符的bit位组成的pair。  
用bit表示限定符，在增删改查方面效率都很高。  
将限定符的bit和类型分离保存的好处是，不需要针对不同的限定符也复制出不同的Type对象（比如，const int或者volatile int都只需要指向同一个int类型），这就减少了内存开销，在区分Type时也不需要考虑限定符信息。  
实现上，最常见的2个限定符（const和restrict）保存在指向Type的指针的最低位，还包含一位标识是否存在其他的限定符（新的部分要分配在堆上）。所以QualType的内存size和指针基本一致。  
> QualType在这里：clang/include/clang/AST/Type.h。
> ```c
> class QualType {
> ...
> // Thankfully, these are efficiently composable.
> llvm::PointerIntPair<llvm::PointerUnion<const Type *, const ExtQuals *>,
>                      Qualifiers::FastWidth> Value;
> ```
> 其中，PointerIntPair这个类将一个指针和一个int合在一起存储，低位bit放int，高位放指针本身；在保证指针值完整保留的场景下可以这样来节省空间。     

## 声明name信息
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
C++重载操作符的类型。name是其拼写，比如：operator+或者operator new []。可通过N.getCXXOverloadedOperator()获取重载的操作符类型（OverloadedOperatorKind的值）[^overloadop]
- CXXLiteralOperatorName  
C++11中的字面操作符。name是其定义的后缀，比如operator "" _foo的name是_foo。使用N.getCXXLiteralIdentifier()来获取对应标识符的IdentifierInfo*信息。  
- CXXUsingDirective  
C++ using指令。实际上using指令不算是NamedDecl类，放到这里是因为实现上方便用DeclContext类来保存其值。

> OverloadedOperatorKind见：clang/include/clang/Basic/OperatorKinds.h与clang/include/clang/Basic/OperatorKinds.def

DeclarationName实例很容易被创建、复制、比较。通常情况下（标识符，0或1参数的OC selector），只需要一个指针长度的存储空间，其他情况则需要紧密、独立的存储。DeclarationName可以通过bit比较来确定是否相等，也可以通过>,<,>=,<=等操作进行排序（主要指标识符，可以通过字母排序；其他类型则排序不确定）也可以被存放在llvm的DenseSet和DenseMap中。  
DeclarationName实例根据其name的种类不同，有不同的创建方式。普通的标识符和OC selector可以隐式转换为DeclarationName；C++构造器，析构器，重载操作符，转换函数则是从DeclarationNameTable获得的ASTContext::DeclarationNames实例。getCXXConstructorName, getCXXDestructorName, getCXXConversionFunctionName, getCXXOperatorName会各自返回对应的C++特定函数name。  

## 声明上下文
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

### 二次声明与重载
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

### 词法和语义上下文
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

### 透明的声明上下文
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
### 多段定义声明上下文
C++的命名空间有个比较有意思的属性：多次定义，各段定义的声明在效果上会最终合并起来（从语义角度看）比如，下面两段代码是等价的。

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

## ASTImporter
ASTImporter类将AST节点从一个ASTContext导入另一个。可参考ASTImporter和import算法描述了解更多信息。

### 抽象语法图
和名字不同，Clang的AST并不是一个真的树，而是带回路的有向图。有向图的一个示例是ClassTemplateDecl与其模板实例化后的CXXRecordDecl。实例化之后的CXXRecordDecl描述了该类模板的成员和方法，ClassTemplateDecl则记录了模板相关的信息，比如，模板参数等。ClassTemplateDecl::getTemplatedDecl()可以获得实例化的CXXRecordDecl类，CXXRecordDecl::getDescribedTemplate()反过来可以获得其所实例化的模板类；所以这两个模板与实例的节点之间就存在一个回路。AST中也存在其他不同的回路。

### 结构等效性
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

### 二次声明链
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
```
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

### 导入过程的遍历
节点相关的导入机制在ASTNodeImporter::VisitNode()相关函数中实现，比如VisitFunctionDecl()。在导入声明时，首先会导入用于调用该节点的构建器所需要的信息，所有需要后续设置的值在节点被创建之后设置。比如，针对FunctionDecl的情况，首先需要导入其声明所在的声明上下文，然后创建FunctionDecl这个类，再之后才导入函数的实现。这说明，在AST节点之前实际存在隐式的依赖关系；这些依赖关系决定我们从源头中按照何种顺序访问节点。实现中，按照常规图遍历算法（比如DFS）的思想，导入时会在ASTImporter::ImportedDecls中记录已经访问过的节点，创建新节点时，会直接加入到ImportedDecls中，只有在将新节点加入之后，才能处理新的声明的导入，否则会没法处理循环依赖的情况。为了强制保证按照上面的顺序执行，所有的AST节点的构造器都会被包装在GetImportedOrCreateDecl()。这个包装器保证新创建的节点会立马被标记为已导入；另一方面，如果一个声明被标记为已导入，那么就直接返回该声明在目标context中的对应节点。所以，直接调用一个声明的::Create()方法会导致错误，不允许这么做。  
即便使用了GetImportedOrCreateDecl()，如果导入方式错误，也可能出现导入无限递归的情况。考虑导入A时，导入B需要先于A的创建之前执行（A的构造器可能依赖B的引用），然后导入B也依赖A的先执行。为了保证针对模板的场景，也可以跳出循环依赖，需要一些额外的关注：只有在CXXRecordDecl创建之后，才能标记为该模板已被实例化。实践中，在目标上下文中创建节点之前，需要防止导入A的构造器不需要的节点。  

### 错误处理
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


