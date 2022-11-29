
这一部分库的名字可能要起得更好一点。这些“基础”库包括：追踪、操作源码buffer和包含的位置信息、诊断、符号、目标平台抽象、以及语言子集的偏基础类的util逻辑。  
部分架构只针对C语言生效（比如`TargetInfo`），其他部分（比如`SourceLocation`, `SourceManager`, `Diagnostics`,
`FileManager`）可以用于非C的其他语言。可能未来会引入一个新的库、把这些通用的类移走、或者引入新的方案。  
下面会根据依赖关系，按顺序描述基础库的各个类。

# 诊断子系统

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

## The Diagnostic*Kinds.td files
根据需要使用的库，在clang/base/Diagnostic*Kinds.td相应文件中增加一个入口点就可以创建诊断。tblgen会根据文件创建唯一id，严重级别，英文翻译，格式化字符串等。  
这个唯一id在命名上也包含一些信息。有的id以err_，warn_，ext_开头，将严重级别列入到id里面。这些严重级别的枚举与产生相应诊断的C++代码关联，所以这个级别简化有一点意义。   
诊断的严重级别包括这些：{NOTE, REMARK, WARNING, EXTENSION, EXTWARN, ERROR}。ERROR这个诊断说明，代码在任何情况下都是不能被接受的；如果产生了一个error诊断，代码的AST可能都没有完全构建好。EXTENSION 和 EXTWARN 用于Clang可以兼容的语言扩展，也就是说，Clang仍然可以构建AST，但是诊断会提示说代码不是可移植的；EXTENSION 和 EXTWARN 的区别在于，默认情况下，前者是被忽略的，而后者会提示警告。WARNING说明，代码在语法规则下是合法的，但是可能有些地方会有二义性。REMARK则说明相应的代码没有产生二义性。NOTE的话，一般是对之前的诊断做补充（没有实际意义）。  
上面这些级别可以映射到诊断子系统的实际输出的levels信息（Diagnostic::Level 枚举, 包括Ignored, Note, Remark, Warning, Error, Fatal）。Clang内部支持一种粗粒度的映射机制，可以让差不多所有的严重级别都可以和level对应上。不能映射的只有NOTES——其级别依赖前面的诊断——以及ERROR，只能映射到Fatal（换句话说，没法把ERROR级别映射到warning level）。  
诊断映射的应用场景很多。比如，-pedantic这个选项会使得EXTENSION映射到Warning, 如果指定了-pedantic-errors选项，EXTENSION就是Error了。这种机制可以实现类似-Wunused_macros, -Wundef 这样的选项。  
映射Fatal一般只能用于过于严重，从而导致错误恢复机制也无法恢复的情况（然后带来成吨的错误）。比如说，#include文件失败。  

## 格式化字符串

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
诊断的参数通过带编号的方式引用：%0-%9，具体编号取决于生成诊断的C++代码。超过10个参数的话，可能某些地方得再考虑一下（笑）。和`printf`不同，参数在字符串的位置，可以和传递的顺序不同；比如可以通过"%1 %0"的方式交换2个参数。%和数字之间部分是格式化指令；如果没有这些指令，参数就只会实例化成一个（常量）的字符串。  
制定英语格式字符串一些最佳实践如下：
- 短一点。不要超过DiagnosticKinds.td的80长度限制，这样不会导致输出时丢失，也可以让你考虑怎么通过诊断信息表达出更重要的点。
- 多利用位置信息。用户可以看到代码的行和具体的位置，所以不用在字符串中告知比如类似第4个参数有问题之类的。
- 不要大写，结尾不要带.（英文句号）
- 如果要引用什么东西，用单引号  
诊断不要用随机的字符串做参数：比如格式化字符串是“you have a problem with %0” 然后传参是“your argument”或者 “your return value” ；这么做不利于翻译诊断文本到其他语言（因为可能文本被翻译了，但是参数仍然是英文的）；C/C++的关键字（比如auto, const, mutable等），以及操作符（/=）这类的情况除外，不过也要注意pointer或者reference不是关键字。在这些之外，你可以用代码中出现的所有的东西（变量名、类型、标记等）。使用select格式可以以很本地化的方式达到这样的目的，见下文。

## 格式化诊断参数
参数是完全在内部定义的，属于多个不同的类别：整数、类型、名字、随机字符串等。根据参数类别不同，格式化方式也不同。这样就可以让DiagnosticConsumer在需要用特殊表达的情况下，就可以了解参数的意义（可以认为是Clang中MVC思想的体现）
下面是Clang支持的参数格式化方式：


"s"格式  
示例： "requires %1 parameter%s1"  
所属类型： 整数   
描述：这是个简单的整数格式化方式，主要用于生成英文的诊断信息。如果这个整数（%1位置的整数）是1，%s1那里什么都不输出；否则%s1那里输出1。 这种方式可以让诊断内容更符合一些简单的语法，不用生成"requires %1 parameter(s)"这种不太优雅的表达。

“select” 格式  
示例: "must be a %select{unary|binary|unary or binary}2 operator"  
所属类型：整数  
描述：这个格式可以把几个相关的诊断合并成1个，不需要把这些诊断的diff用单独的参数替代。不同于指定参数为字符串，这个诊断输入整数参数，格式化字符串根据参数选择对应的选项。本例中，%2参数必须是[0..2]范围的整数。如果%2是0，那么这里就是unary，1的话就是binary，2的话就是“unary or binary”。这使得翻译成其他语言时，可以根据语法填入更合理的词汇或者整条短语，而不需要通过文本的操作处理。被选到的字符串会在内部进行格式化。

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
 
Description: 这个格式符可以避免在大量的诊断中进行逐字重复。%sub的参数必须是TextSubstitution表生成记录。其实例化时需要指定所有用到的参数，在实例化时，后面的下标会按照顺序重新排列。注意，这个用于实例化的字符串本身在未实例化格式必须是合法的。  

> "sub"格式稍微解释一下。  
> "sub"这里可以认为是"substitution"的缩写，主要作用是支持诊断信息内部的二次实例化  
> 这里是一个Clang提供的诊断，主要用于选择特定的成员：  
> ```
> def select_special_member_kind : TextSubstitution<
>  "%select{default constructor|copy constructor|move constructor|"
>  "copy assignment operator|move assignment operator|destructor}0">;
> ```
> 从这里看出来，这个诊断格式的作用是在类的构造函数和析构函数这些特殊成员中选一个，用于更外层的诊断。  
> 如果不用sub，就必须把%select{....|destructor}这一长串内容在外层诊断中复制一份，这样诊断信息会很长很难维护。  
> 而这个被选的成员，在外层诊断中，本身也可能以不同index的参数被使用，比如有的诊断可能让这个信息在第1个位置，有的则是第3个，所以需要sub的索引也要能按照外部调用需要重新排列。


## 产生诊断
在Diagnostic*Kinds.td文件中创建入口点之后，需要编写代码来检测相应情况并且生成诊断。Clang中的几个组件（例如preprocessor, `Sema`等）提供了一个辅助函数"`Diag`"，这个函数会创建诊断并且接受参数、代码范围以及诊断相关的其他信息作为参数。  
比如，下面这段代码产生了一个二元表达式相关的错误诊断。  
```
if (various things that are bad)
  Diag(Loc, diag::err_typecheck_invalid_operands)
    << lex->getType() << rex->getType()
    << lex->getSourceRange() << rex->getSourceRange();
```
这里展示了Diag方法的使用方式：接受一个location（SourceLocation对象）以及诊断的枚举值（来自Diagnostic\*Kinds.td文件）。如果这个诊断需要参数，那么这些参数通过<<操作符指定：第一个参数就是%0，第二个是%1，以此类推。这个诊断接口支持指定多种类型的参数，包括整数的：int, unsigned int。字符串的const char*和std::string，用于名称的`DeclarationName`和`const IdentifierInfo *`，用于类型的`QualType`，等等。`SourceRange`也可以通过<<指定，不过并没有特定的顺序要求。  
正如上面所示，添加诊断、生成诊断的流程很简洁直接。最困难的地方在于怎么准确的向用户描述诊断要表达的内容，选择合适的词语组织，并且提供需要的信息来正确格式化。好消息是，产生该诊断的调用，应该和诊断信息的格式化方式、以及渲染所用的语言（展示给用户的诊断自然语言）必须是完全独立的。

## “建议修改”提示
有些情形下，如果可以明确看出，代码做一些小的修改就可以修正问题，编译器会抛出相应的（建议修改）诊断。比如，语句后缺少分号；或者使用很容易被现代形式改写的废弃的语法。在这些情形下，Clang在抛出诊断并且优雅恢复方面做了很多工作。  
不过呢，对于修复方式很明显的情况，诊断可以直接表达成描述如何修改代码来修复问题的提示（一般被叫做“建议修改”提示）。比如，添加缺失的分号或者用更好的方式重写废弃的结构。下面是一个C++前端的例子，用来警告右移操作符的含义在C++98与C++11中有不同。  
```
test.cpp:3:7: warning: use of right-shift operator ('>>') in template argument
              will require parentheses in C++11
A<100 >> 2> *a;
       ^
  (       )
```
上文中的建议修改提示就是需要加上小括号，并且准确的指出了需要插入小括号的代码的位置。这个提示本身以一种抽象的方式描述了需要做的修改，这里是在^号下面加了一行，通过诊断的文本输出“插入”的行为。其他的诊断客户端（这里指会调用诊断接口的程序）可能会选择不同的方式来展示这个代码（比如说内嵌标记），甚至直接帮用户自动改掉。  
针对错误和警告的建议修改提示需要遵循这些规则：
- 将`-Xclang -fixit`参数传递给driver的情况下，这些建议修改提示会自动应用，所以这些建议只能在非常匹配用户的期望的时候才能使用。
- 如果应用了建议修改提示，那么Clang必须能从错误中恢复。
- 针对警告的建议修改提示，不能改变代码的逻辑。不过提示可以用来明确用户的意图，比如建议在操作符优先级不太明显区分的情况下加上括号。

如果某个建议不能遵从上面的规则，那么就把这个建议改成NOTE，针对note的提示不会自动应用。

建议修改提示，通过`FixItHint`类进行描述；类对应的实例也需要和高亮代码段、参数一样，通过<<操作符传给诊断。创建一个提示对象有如下三个构造器：
- FixItHint::CreateInsertion(Loc, Code)  
  提示内容：将指定的参数Code插入到Loc的对应代码位置前面。
- FixItHint::CreateRemoval(Range)  
  提示内容：Range所指定的代码段建议删除
- FixItHint::CreateReplacement(Range, Code)  
  提示内容：Range所指定的代码段建议删除，并且由Code对应的字符串替代

## DiagnosticConsumer接口    
代码根据参数和其余的相关信息生成了诊断之后，会提交给Clang处理。前文描述，诊断机制会执行一些过滤，将严重级别映射到诊断level，然后（如果诊断没有映射成ignored的情况下）以诊断信息为参数，调用DiagnosticConsumer接口的某个实现。    
实现接口的方式多种多样。比如，最普通的Clang的DiagnosticConsumer实现(类名是TextDiagnosticPrinter），就是把参数根据不同的格式化规则转成string，然后输出文件/行数/列数，该行的代码，代码段，以及^符号。当然这种行为并不是要求的。    
另一个 DiagnosticConsumer 的实现是 TextDiagnosticBuffer 类，当Clang使用了-verify参数的时候会被调用。这个实现只会捕获并且记录诊断，然后比较生成的诊断信息和某个期望的列表是否一致。关于-verify的详细说明请参考Clang API文档的VerifyDiagnosticConsumer类。  
这个接口还有很多其他的实现，所以我们更希望诊断可以接受表达能力比较强的结构化信息作为参数。比如，可以通过HTML输出来给declaration的符号名加上定位链接。也可以通过GUI的方式，点击展开typedef；实现这种方式时，需要将更重要、信息量更大的类型信息，而不是单纯的字符串作为参数传递给这个接口。  

## Clang增加多语言翻译
目前还不行。诊断的字符串需要用UTF-8字符集编码，调用的客户端在需要的情况下可以将翻译相应的。翻译的时候需要整个替换掉诊断中的格式化字符串。

# SourceLocation和SourceManager类
SourceLocation类用来描述代码在程序中的位置。重点信息如下：
- sizeof(SourceLocation)越小越好，因为可能有大量的SourceLocation对象会嵌入AST节点内部，以及节点间传递。目前是32个bit
- SourceLocation是一个简单类型值的对象（没有指针，依赖等复杂结构），这样就可以被高效率的拷贝。
- SourceLocation可以描述任何一个输入文件的任何一个字节。包括在符号中间，空格，三字节的字符（比如utf8文本）等
- 在处理相应位置的代码时，SourceLocation要标记当前的#include栈为active。比如说，如果某个SourceLocation对象对应了一个token，那么当词法分析解析这个token的时候，所有的active的#include栈集合都需要记录在这个SourceLocation对象中。这样就可以在诊断时输出#include栈了。
- SourceLocation有能力描述宏的展开，不论是代码中的原始文本，还是最终的实例化内容。

在实践中，SourceLocation常常和SourceManager配合来描述某个代码位置的两方面信息：拼写位置，展开位置。对于大部分的符号来说，这两个一致。不过需要展开宏（或者_pragma指令定义的符号）的地方，它们就分别用来描述这个符号本身的位置以及使用的位置（宏展开或者_pragma指令位置）

# SourceRange和CharSourceRange
Clang中，大部分的代码段都可以通过[first, last]区间表达，first和last分别指向代码段开头与结尾的符号。比如下面这段语句的SourceRange
```
x = foo + bar;
^first    ^last
```
为了从这种表达转成基于字符的表达，last的位置需要调整成为指向token的结尾，调整可以通过Lexer::MeasureTokenLength() 或者 Lexer::getLocForEndOfToken()方法实现。极少情况下，我们需要字符级别的代码范围，这个时候可使用CharSourceRange类。