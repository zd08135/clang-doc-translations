
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
- Lexer会使用LangOptions来设置是否开启三字符[^1]解析，是否识别C++和Object-C的关键字等等。

[^a]:三字符：一些语言的键盘无法正确输入某些符号，则输入三字符并在解析时替换成该符号。参考：https://en.wikipedia.org/wiki/Digraphs_and_trigraphs.








