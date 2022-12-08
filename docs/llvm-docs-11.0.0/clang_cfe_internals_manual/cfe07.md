词法分析库包含一些跟处理词法分析和预处理紧密相关的类，其主要接口是通过庞大的Preprocessor类提供。包含为了从TU中连贯地读取符号而需要的多种状态。
Preprocess对象中的核心接口是Preprocessor::Lex方法，这个方法从预处理器的流中返回符号。预处理器可以通过如下两类解析器读取符号：词法解析的buffer（通过Lexer类）和符号流（通过TokenLexer）。

# Token类
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

# 注释符号
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

如上所述，注释符号并非由预处理器返回，但是需要遵循语法分析器的格式要求。这意味着，语法分析器必须了解什么时候注释需要出现并且以合适的格式生成之。这某种程度上和语法分析器处理C99规范：Translation Phase 6 of C99: String Concatenation (see C99 5.1.1.2)的方式类似。处理字符串连接的时候，预处理器就区分tok::string_literal和tok::wide_string_literal两种符号，然后语法分析器将后面跟着的一串语法格式符合字符串常量的全部纳入解析。  
为了达到这一目标，只要parser解析到需要tok::identifier或者tok::coloncolon的时候，它就调用TryAnnotateTypeOrScopeToken或者 TryAnnotateCXXScopeToken来生成这个token。这些方法会尽可能在允许的时候，生成注释符号并替代当前符号。如果当前的符号不能用于生成注释符号，就保留为一个标识符或者::符号。  

> （C99 5.1.1.2 第6条内容： Adjacent string literal tokens are concatenated，相邻的字符串常量token需要连到一起，比如`"a" "b" "c"`解析时需要按照`"abc"`处理）

# Lexer类
Lexer类提供了从源码buffer中进行词法分析获取符号并确认其含义的机制。Lexer的实现很复杂，因为它必须处理并没有进行拼写消除的原始buffer（在使用了拼写消除的基础上可以获得比较好的性能），但是反过来需要特别小心的编码，同时也要在性能上满足一定的标准（比如，处理注释的代码在x86和powerpc主机上就使用了向量指令）
Lexer包含若干个有趣的feature。  
- Lexer可以在原始模式下操作。原始模式中，可以采用若干机制来快速分析一个文件（比如，忽略标识符的查找、忽略预处理符号、特殊处理EOF等）。这种模式可以用来分析比如#if 0包含的语句块（快速跳过）
- Lexer可以捕获并处理注释。这个能力在使用-C选项的预处理模式中使用，预处理模式会输入注释内容，并由来获取哪些需要报错的注释信息。
- lexer可以工作在ParsingFilename模式，这个模式主要是预处理时，处理#include指令时使用。这个模式处理时会将<的内容返回一个string，而不是这个文件中的代码对应的token
- 分析（#之后的）预处理指令时，Lexer会进入ParsingPreprocessorDirective 模式，这模式会让分析器在处理换行时返回EOD。
- Lexer会使用LangOptions来设置是否开启三字符解析，是否识别C++和Object-C的关键字等等。

> 三字符：一些语言的键盘无法正确输入某些符号，则输入三字符并在解析时替换成该符号。参考：https://en.wikipedia.org/wiki/Digraphs_and_trigraphs.

# TokenLexer类
TokenLexer类是一个符号的provider，可以从来自其他地方的token中返回一些token。
典型应用包括：1) 从宏的展开中返回符号。2) 从一个比较随意的符号buffer中返回符号，这个通过_Pragma使用，主要用于C++语法解析时，防止无法停止的前探。

# MultipleIncludeOpt类
这个类实现一个简单的小状态机来识别标准的#ifndef XX / #define的习惯用法，这个用法主要用来防止头文件的重复#include。如果一个buffer用了这个惯用法，并且后面跟着#include指令，预处理器就可以很简单地检查这个标记是否定义。如果已经定义了，预处理器就会整个忽略include这个头文件。


---------------------    

[原文](https://releases.llvm.org/11.0.0/tools/clang/docs/InternalsManual.html#introduction)