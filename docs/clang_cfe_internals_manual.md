
# 基本说明

## 源码地址

参考llvm github:  
<https://github.com/llvm/llvm-project.git>  
<https://gitee.com/mirrors/LLVM.git>  （github地址的国内镜像，每日同步）  

## 版本选择

基于clang11版本文档翻译  
<https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html>

选择11.0版本的代码，具体版本如下：

```
commit 1fdec59bffc11ae37eb51a1b9869f0696bfd5312 (HEAD, tag: llvmorg-11.1.0-rc3, tag: llvmorg-11.1.0, origin/release/11.x)
Author: Andi-Bogdan Postelnicu <abpostelnicu@me.com>
Date:   Wed Feb 3 17:38:49 2021 +0000

    [lldb] Fix fallout caused by D89156 on 11.0.1 for MacOS

    Fix fallout caused by D89156 on 11.0.1 for MacOS

    Differential Revision: https://reviews.llvm.org/D95683
```
## 平台

本文的中的附加内容需要实际开发运行的部分，相关的开发调试主要基于Linux平台(Ubuntu/Fedora/CentOS）  
推荐使用VSCode作为IDE开发：<https://code.visualstudio.com/>

## 备注


TODO: **未来可能会按照clang版本形式，将本文档也划分成不同版本**  
FIXME: **文中出现的其他链接，部分会链接到llvm docs的原始网站，如果未来对应文档也有翻译的话，会同步修正为内部的链接。**


---------------
# ---以下为正文---

# 介绍

本文档描述了clang前端中，一些重要API以及内部设计，旨在让读者可以既可以掌握一些高层次的信息，也可以了解背后的一些设计思路。
本文更针对探索clang内部原理的读者，而不是一般的使用者。下面的描述根据库的分类进行组织，但是并不会描述客户端如何使用它们。

# LLVM支持库

LLVM支持库libSupport提供了一些底层库和[数据结构](https://llvm.org/docs/ProgrammersManual.html)，包括命令行处理、不同的container以及用于文件系统访问的系统抽象层。

# Clang的基础库

这一部分库的名字可能要起得更好一点。这些“基础”库包括：追踪、操作源码buffer和包含的位置信息、诊断、符号、目标平台抽象、以及语言子集的偏基础类的util逻辑。  
部分架构只针对C语言生效（比如`TargetInfo`），其他部分（比如`SourceLocation`, `SourceManager`, `Diagnostics`,
`FileManager`）可以用于非C的其他语言。可能未来会引入一个新的库、把这些通用的类移走、或者引入新的方案。  
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
示例： "requires %1 parameter%s1"  
所属类型： 整数   
描述：这是个简单的整数格式化方式，主要用于生成英文的诊断信息。如果这个整数（%1位置的整数）是1，%s1那里什么都不输出；否则%s1那里输出1。 这种方式可以让诊断内容更符合一些简单的语法，不用生成"requires %1 parameter(s)"这种不太优雅的表达。

“select” 格式  
示例: "must be a %select{unary|binary|unary or binary}2 operator"  
所属类型：整数  
描述：这个格式可以把几个相关的诊断合并成1个，不需要把这些诊断的diff用单独的参数替代。不同于指定参数为字符串，这个诊断输入整数参数，格式化字符串根据参数选择对应的选项。本例中，%2参数必须是[0..2]范围的整数。如果%2是0，那么这里就是unary，1的话就是binary，2的话就是“unary or binary”。这使得翻译成其他语言时，可以根据语法填入更有意义的词汇或者整条短语，而不需要通过文本的操作处理。被选到的字符串会在内部进行格式化。

“plural” 格式  
示例："you have %1 %plural{1:mouse|:mice}1 connected to your computer"  
所属类型: 整数  
描述：这个格式适用于比较复杂的英文的复数形式。这个格式的设计目的是处理对复数格式有一定要求的语言，比如波罗的海一些国家的语言。这个参数包含一系列的expression/form的键值对，通过:分隔。从左到右第一个满足expression为true的，作为结果输出。  
expression可以没有任何内容，这种情况下永远为真，比如这里的示例（:mice）。除此之外，这个是若干个数字的condition组成的序列，condition之间由,分隔。condition之间是或的关系，满足任意一个condition就满足整个expression。每个数字condition有下面几种形式：  
- 单个数字：参数和该数字相等时满足condition，示例："%plural{1:mouse|:mice}4" 
- 区间。由[]括起来的闭区间，参数在该区间范围内时满足condition，示例："%plural{0:none|1:one|[2,5]:some|:many}2" 
- 取模。取模符号% + 数字 + 等于号 + 数字/范围。参数取模计算后满足等于数字/在区间内则满足condition，示例："%plural{%100=0:even hundred|%100=[1,50]:lower half|:everything else}1" 

这个格式的Parser很严格。只要有语法错误，即便多了个空格，都会导致parse失败，不论什么expression都无法匹配。

“ordinal” 格式  
Example: "ambiguity in %ordinal0 argument"  
Class: Integers  
Description: 这个格式把数字转换成“序数词”。1->1st，3->3rd，只支持大于1的整数。 这个格式目前是硬编码的英文序数词。

“objcclass” format  
Example: "method %objcclass0 not found"  
Class: 声明名字  
Description: （object-c专用，后面翻译） This is a simple formatter that indicates the DeclarationName corresponds to an Objective-C class method selector. As such, it prints the selector with a leading “+”.

“objcinstance” format  
Example: "method %objcinstance0 not found"  
Class: DeclarationName  
Description: （object-c专用，后面翻译） This is a simple formatter that indicates the DeclarationName corresponds to an Objective-C instance method selector. As such, it prints the selector with a leading “-“.

“q” format  
Example: "candidate found by name lookup is %q0"  
Class: NamedDecl *  
Description: 这个格式符号表示输出该声明的完全限定名称，比如说，会输出std::vector而不是vector

“diff” format  
Example: "no known conversion %diff{from $ to $|from argument type to parameter type}1,2"  
Class: QualType  
Description: 这个格式符以两个QualType为参数，尝试输出两者的模板的区别。如果关闭了输出树，那么就会输出{}括号内部|符号之前的部分，输出时\$符号被替换。如果开启了树输出，那么输出括号内|符号之后的部分，并且在此消息之后会输出类型树。  

给Clang诊断系统加入新的格式符很容易，但是添加之前需要讨论一下其必要性。如果需要创建大量重复的诊断信息，（并且/或者）有创建新的用的上的格式符的想法，请发到cfe-dev邮件列表里面。  

“sub” format  
Example: 下面的TextSubstitution类型的记录定义:
```
def select_ovl_candidate : TextSubstitution<
  "%select{function|constructor}0%select{| template| %2}1">;
```
可以被用到  
```
def note_ovl_candidate : Note<
  "candidate %sub{select_ovl_candidate}3,2,1 not viable">;
```
这种写法和直接使用"candidate %select{function|constructor}3%select{| template| %1}2 not viable"是等效的。  
 
Description: 这个格式符可以避免在大量的诊断中进行逐字重复。%sub的参数必须是TextSubstitution表生成记录。其实例化时需要指定所有用到的参数，The substitution must specify all arguments used by the substitution, and the modifier indexes in the substitution are re-numbered accordingly. The substituted text must itself be a valid format string before substitution.  


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
注释符号由语法分析器生成，并且会被再次注入到预处理器的符号流里面（会替代一些已经存在的符号）。因为注释符号只存在于已处理完毕预处理阶段的符号中，所以不需要追踪只有预处理才需要的标记，比如说“本行开头”之类的。另外，一个注释符号可以“覆盖”一个预处理符号序列（比如：`a::b::c`是5个预处理符号），所以，注释符号的字段内容和普通符号的字段有差异（当然字段内容是复用的）：  
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

### 查找问题
从源上下文导入声明时，需要检查在目标上下文中是否存在名义相同，且结构等效的节点。如果源上下文的节点是一个定义，目标中找到的也是一个定义，那么就不在目标上下文中创建新的节点，而是标记目标上下文中的节点为已导入。如果找到的定义和源上下文中的定义名字一样，但是不是结构等效的，那么（C++的话）就会出现一个违反ODR的错误。如果源节点不是定义，就将其添加到目标节点的二次声明链。这个行为在合并包含相同头文件的不同TU对应的AST时很有必要。比如，（注：同一个类型）我们希望只存在一个std::vector的定义，即便在多个TU中都包含了<vector>头文件。  
为了找到一个结构等效的节点，可使用常规的C/C++查找函数：DeclContext::noload_lookup()和DeclContext::localUncachedLookup()。这些函数遵循C/C++的名字隐藏的原则，一些特定的声明在声明上下文是无法找到的，比如unamed声明（匿名结构体），非第一次出现的友元声明，模板特化等。这个问题可能导致如果支持常规的C/C++的查找，在合并AST时，会创建冗余的节点，冗余的节点又会导致在节点间结构等效型判定时出错。因为上面这些原因，创建一个查找类，专门用于注册所有的声明，这样这些声明就在导入之后，就可以被查找了。这个类叫：ASTImporterLookupTable。这个查找表会在导入同一个目标上下文的不同ASTImporter之间共享。这也是说明只能通过ASTImporterSharedState进行导入相关查询的原因。

#### ExternalASTSource
ExternalASTSource是和ASTContext关联的抽象接口。它提供了通过迭代或者名字查找来访问声明上下文中的声明的能力。依赖外部AST的声明上下文需要按需加载其声明信息。这就说明（在未加载时）声明的列表（保存在链表中，头是DeclContext::FirstDecl）可能是空的，不过类似DeclContext::lookup()的成员函数可能会初始化加载流程。  
一般来讲，外部源代码是和预编译头文件相关的。比如，如果从预编译头文件中加载一个类，那么该类的成员只有在需要在该类的上下文中进行查找时才会被加载。  
考虑LLDB的情况，一个ExternalASTSource接口的实现类，是和对应表达式所在的AST上下文相关联的。这个实现是通过ASTImporter被发现的。通过这种方式，LLDB可以复用Clang的分析机制来从调试数据（比如DWARF，调试信息存储格式）中合成底层的AST。从ASTImporter的角度看，这意味着源和目标上下文中，可能包含存储了外部词法信息的声明上下文。如果目标上下文中的DeclContext对象包含了外部词法信息的存储，就必须特殊处理已经被加载的声明信息。否则，导入过程会变得不可控。比如，使用常规的DeclContext::lookup()在目标上下文中查找存在的声明，在导入声明的过程中，lookup方法会出现递归调用从而导致出现新的导入操作。（在初始化一个尚未注册的查找时，已经开始从源上下文中导入了）所以这里需要用DeclContext::noload_lookup()来代替。

### 类模板的实例化
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

在foo.cpp中，使用了(1)这个构造器，显式将a初始化为3，那么InitListExpr {0}这个初始化表达式就没被使用，也没有实例化相关的AST节点。然后，在bar.cpp中，我们使用了(2)这个构造器，没有使用初始化a的构造器，那么就会执行默认的InitListExpr并实例化。在合并foo.cpp和bar.cpp的AST时，就必须为X<char>这个模板实例化创建全部所需的节点。也就是说，如果找到了ClassTemplateSpecializationDecl对象，就需要把源上下文中，ClassTemplateSpecializationDecl对象的所有字段采用这个方式合并：如果一个InitListExpr不存在就复制。这个机制也适用于默认参数和异常规格的实例化。  

### 声明可见性
在导入外部可见的全局变量时，查找过程会找到同名变量，但是却是静态可见的。明确一下，就是不能把他们放到同一个二次声明链中。这个情况对函数也适用。而且，还需要特殊注意匿名命名空间的枚举、类。那么，我们会在查找结果中过滤，只考虑和当前导入的声明具有相同可见性的结果。  
这里认为，匿名命名空间的两个变量，只有来源于同一个源AST上下文的才认为是可见性相同的。  

### 冲突名字的处理策略
导入过程中，我们会查找是否存在有同名的声明，并且根据其可见性进行过滤。如果找到了声明，并且和源中的不是结构等效的，那么就报一个名字冲突的错误（C++中的ODR违规）。在此场景中，会返回Error对象并且将这个对象设置到声明中。不过，一些调用ASTImporter的客户端可能会要求不同的处理方式，比如不需要太保守的，更自由一点的错误处理策略。  
比如，代码的静态分析的客户端，会倾向于即便出现名字冲突时也创建节点。对进行特定工程进行CTU(Cross Translation Unit)分析时，必须知道可能存在全局的声明和来自其他TU的声明冲突，但是这些全局声明并不被本TU外部引用的情况。理想情况，这一部分声明需要放在匿名命名空间中。如果我们比较自由的处理这类冲突，那么CTU分析可以发现更多的结果。注意，支持选择不同的名字冲突处理策略的特性还尚未完善。

## CFG类
CFG类被设计用来表达一个语句的代码级的控制流图。CFG比较典型应用与函数体的构建上（一般作为CompoundStmt的实例），当然也会用来表达一些Stmt子类的控制流，比如简单的表达式。控制流图在处理在对函数进行流敏感或者路径敏感的程序分析时可用。  

### 基本语句块
结构上，CFG是实例是一些基本语句块的集合。每个语句块都是一个CFGBlock类的实例，CFGBlock只简单包含了排好序的Stmt*序列（每个Stmt*代表AST中的一个语句）。块中语句的顺序代表语句间控制流的无条件的流转关系（就是按照代码顺序一条接一条执行）。条件控制流通过语句间的边表达。可以通过CFGBlock::*iterator来遍历CFGBlock中的语句。    
一个CFG对象包含其表达的控制流图，以及CFGBlock实例集合。CFG内部的每个CFGBlock对象被在CFG内部唯一编号（通过CFGBlock::getBlockID()）。目前实现中，这个编号根据语句块创建的顺序指定，但是除了编号独立和范围[0..N-1]（N是CFG中CFGBLock对象的个数）之外，不能假定其编号的机制。  

### 入口/出口语句块
每个CFG包含两个特殊的块：入口块（通过CFG::getEntry()）访问，没有边指向该块；以及出口块，（通过 CFG::getExit()访问），没有边从该块指出。这两个块不包含语句，其作用是指明一段实体代码的入口和出口，比如函数体。这些空块的存在简化了从CFG顶层进行分析的实现。  
### 条件控制流
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

## Clang AST中的常量折叠
在Clang前端中，有一些场景下，常量和常量折叠是很重要的。首先，通常情况下，希望能让AST尽可能贴近源代码。如果代码中写了“5+4”，我们希望在AST描述这两个常量的加法操作，而不是直接折叠成“9”。所以，不同方式处理常量折叠，其最终会通过树遍历的方式来实现，从而可以处理不同的场景（注：5+4在AST中，会通过5,+,4三个AST节点表示，所以5+4的处理其实是树的遍历）。  
不过，有一些场景是要求C/C++必须进行常量折叠的。举例，C标准以很精细、特殊化的方式定义了“整数常量表达式(i-c-e)”。语言中很多场景有需要i-c-e（比如bitfield的大小，case语句的值等），这样就必须进行常量折叠来进行语义检查（比如，判断bitfield的长度是否非负，case语句没有重复）。希望Clang可以很“教条”的方式处理：诊断出需要使用i-c-e而没有使用的场景，但是只有在使用-pedantic-errors时才报错，否则都通过编译。  
为了兼容真实世界的代码，需要有一点取巧的方式。考虑一种特殊情况，gcc的某个历史版本，会接受一个巨大的表达式超集作为i-c-e，然后，很多真实世界的代码都依赖这个不太幸运的特性（包括比如glibc的头文件）。gcc会将任何能被折叠成一个整数常量的都进行该优化。比如，gcc会将case X-X语句优化成case 0，即便x是一个变量。  
另一个问题是，常量是如何和编译器支持的扩展交互的，比如__builtin_constant_p, __builtin_inf, __extension__和其他的。C99没有明确指定这些扩展的语义，i-c-e的定义也没有包含这些。不过，在实际开发时，这些扩展经常会用到，所以必须有合适的方式处理。  
最后，这不仅仅是关于语义分析的问题。代码生成器和其他的客户端也需要具备常量折叠的能力（比如，初始化全局变量），也必须处理C99规定的超集。而且，这些客户端会从扩展中受益。比如，我们知道foo() || 1的计算结果一定是true，但是因为有边际效应，就不能直接替代成true。

### 实现目标
在尝试过多个不同的目标之后，最终综合出了一个设计（注意，编写本文时，不是所有的都被实现了，这一部分是一个设计目标！）。最基本的目标是定义一个简单的递归计算方法（Expr::Evaluate），在AST/ExprConstant.cpp中实现。给定一个“标量"类型（比如整数，浮点，复数，指针）的表达式，这个方法会返回下面的信息：  
- 此表达式是否为i-c-e/一个没有边际效应的通用常量/一个有边际效应的通用常量/一个不可计算或折叠的值
- 这个表达式是否是可以计算的，（如果可以计算）此方法会返回APValue代表计算结果
- 如果这个表达式不能执行，这个方法会返回表达式中所存在的其中一个问题。信息中还包括描述问题位置的SourceLocation，以及解释该问题的诊断ID。这个诊断具有EXTENSION类型。

这些信息可以为客户端提供了所需的一些灵活性，最终也会有针对不同扩展的辅助方法。比如，Sema类需要有一个Sema::VerifyIntegerConstantExpression方法，这个方法调用了Evaluate。如果这个表达式不能折叠，就报告一个错误，然后返回true。如果这个表达不是i-c-e，这个EXTENSION诊断就报告出来。最后，如果AST没问题的话就返回false。  
其他的客户端可以通过不同的方式使用这些信息，比如，代码生成可以直接使用折叠后的结果。  

### 扩展
本节描述一下Clang在常量计算时支持的不同的扩展：
- __extension__：这个表达式会尝试将可以被计算的子表达式替换成i-c-e。
- __builtin_constant_p：这个方法在操作数可以被计算为一个整数、浮点、复数的数字值（而不是指针转换成整形），或者是否是某个字符串首字母的地址（会转换成其他类型）时返回true。特殊例子，如果__builtin_constant_p 是（被自动加了括号）条件操作表达式的条件，那么只有为真的那一部分被考虑，也被折叠。
- __builtin_choose_expr：这个情况
- __builtin_classify_type: 这个一定会返回一个i-c-e
- __builtin_inf, nan, ...: 这些被看成是浮点数常量
- __builtin_abs, copysign, ...: 按照通用的常量表达式处理常量折叠
- __builtin_strlen 和 strlen: 参数为字符串字面常量时，按照i-c-e处理常量折叠

# 语义分析库
这个库由语法分析库在语法分析时调用。如果程序是合法的，语义分析库会构建一个分析结果的AST。
# 代码生成库
代码生成库会以AST作为输出，然后生成LLVM IR代码。
# 如何修改Clang
## 如何增加属性
属性是一些可以被附加到程序结构中的元数据。程序员可以在语义分析时，向编译器传递更多的信息。比如，属性可以改变程序结构代码生成，或者为静态分析提供更多的信息。本文档描述如何向Clang中添加一个自定义的属性，Clang中现有的属性可以参考[这里](https://clang.llvm.org/docs/AttributeReference.html)。
### 属性的基础信息
Clang中，属性在如下三个时机中处理：进行语法分析时，从语法属性转换成语义属性时，语义分析阶段处理该属性时。
属性的语法分析过程由不同的属性对应的句法决定，比如GNU, C++11, 微软各自风格的属性；也包括属性的表定义中所提供的信息。属性对象进行语法分析的最终结果，是一个ParsedAttr类的对象。这些转换后的属性链成一串，附加在声明上。除了关键字属性之外，属性的语法分析由Clang自动进行。当实现属性时，关键字的转换和对应ParsedAttr对象的创建必须手动处理。  
最终，在语法分析属性可以转换成语义分析属性时，会以Decl和ParsedAttr作为参数调用Sema::ProcessDeclAttributeList()方法。语法属性转换成语义属性这个流程依赖于属性的定义和语义要求。转换结果的是一个挂在该Decl上的语义属性对象，可以通过Decl::getAttr\<T\>()获取。
语义属性的结果也通过Attr.td中的属性定义管理。这个定义用于自动生成实现该属性功能的代码，比如clang::Attr的子类，用于语法分析的信息，部分属性的语义检查等。
### include/clang/Basic/Attr.td
为Clang添加新属性的第一步是在include/clang/Basic/Attr.td中添加其定义。这个表生成定义必须继承Attr（表生成，而非语义的）的定义，或者一个或多个其继承者。大部分属性都是继承自InheritableAttr类型，这个类型说明该属性可以被其关联的Decl的二次声明继承。InheritableParamAttr和InheritableAttr类似，不同点在于InheritableParamAttr是作用于参数的。如果某个属性是类型相关的，那么需要继承的类型是TypeAttr，并且也不会生成对应的AST内容。（注意，本文档不涵盖类型属性创建的内容）。一个属性继承IgnoredAttr的话，那么整个属性会被分析，但是只会生成一个忽略的属性诊断，这种场景可以应用于非Clang编译器的需求。  
这个定义包括几项内容，比如属性的语义名称，支持的拼写方式，需要的参数和其他内容。大多数Attr类的表生成类型的成员不需要其继承的定义像默认定义那样完善。不过每个属性至少得包含一个拼写列表，主语列表和文档列表。

#### 拼写
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

#### 主语

属性会关联一个或多个Decl主语。如果这个属性尝试附加到一个和其不关联的主语上，就会自动报一个诊断问题。这个诊断是警告还是错误，取决于这个属性的SubjectList是如何定义的，默认情况是警告。展示给用户的诊断信息由该SubjectList中的主语信息自动确定，当然也可以为该SubjectList指定一个自定义的诊断参数。这些因为主语列表错误而产生的诊断具有diag::warn_attribute_wrong_decl_type或者diag::err_attribute_wrong_decl_type类型，参数的枚举定义在include/clang/Sema/ParsedAttr.h之内。如果之前有一个被加入SubjectList的Decl节点，那么在utils/TableGen/ClangAttrEmitter.cpp中的自动决定诊断参数的逻辑也需要更新。  
默认情况下，SubjectList中的所有主语，要么是DeclNodes.td中的定义的一个Decl节点，要么是StmtNodes.td中定义的一个statement节点，不过也可以通过SubsetSubject创建更复杂的主语。每个这样的对象包含一个相关的base主语（必须是Decl或者Stmt节点，但是不能是SubsetSubject节点）以及一些用来判定某些属性是否属于该主语的自定义节点。比如，一个NonBitField SubsetSubject对象关联一个base主语FieldDecl，这个对象用来检查该FieldDecl对象是否是一个bit位。如果一个SubjectList中有一个SubsetSubject对象，那么就需要同时提供一个自定义的诊断参数。  
针对属性主语的自动化检查在HasCustomParsing != 1的情况下会自动执行。

#### 文档
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

#### 参数
参数可以有选择地指定传给属性的参数列表。属性的参数可以是语法形式的，也可以是语义形式的。比如，如果Args的格式是[StringArgument<"Arg1">, IntArgument<"Arg2">]，那么__attribute__((myattribute("Hello", 3)))就是合法的使用；其在进行语法分析时需要2个参数，对应的Attr子类的构造函数中，针对该语义属性需要1个字符串和1个整形数作为参数。  
每个参数都有名字，以及指明该参数是否可选的标记位。参数相关的C++类型由参数的定义类型决定。如果已存在的参数类型不够用，可以创建新的类型，但是创建新类型时，需要修改utils/TableGen/ClangAttrEmitter.cpp来为新类型提供合适的支持。  

#### 其他属性
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

### 样例
所有针对声明属性的语义处理代码都在lib/Sema/SemaDeclAttr.cpp中，一般都是从ProcessDeclAttribute()函数开始的。如果属性的SimpleHandler标记位为1，那么该属性的处理逻辑是自动生成的，开发者不需要做什么；否则（SimpleHandler != 1），就需要编写新的handleYourAttr()函数，并且放到switch语句中。注意不要直接在switch语句的case中去写实现逻辑。  
在属性定义没有特别指明的情况下，针对语法转换后属性的公共语义检查是自动处理的。公共语义检查包括诊断语法属性是否和对应的Decl节点关联，保证传递的参数个数满足要求的最小值等。  
如果属性添加附加的告警信息，可以在include/clang/Basic/DiagnosticGroups.td中，该属性的拼写之后定义一个DiagGroup，其中的"_"要替换成"_"。如果诊断只有一个，那么直接在DiagnosticSemaKinds.td用InGroup<DiagGroup<"your-attribute">>方式定义也是可以的。  
所有针对新属性的语义诊断，包括自动生成的那些（比如主语和参数个数）都需要有对应的测试用例。  

### 语义处理
大部分的属性实现上都会对编译器有影响。比如，修改生成代码的方式，针对分析pass添加额外的语义检查等。添加属性的定义和转换成语义表示的逻辑之后，剩下的部分就是实现该属性需要的自定义逻辑。  
clang::Decl对象可使用hasAttr<T>的接口来查询该属性是否存在，也可以使用getAttr<T>来获取该属性语义表示的指针。

## 如何增加表达式或者语句
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

