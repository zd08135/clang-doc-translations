
Lex和Parse

最初，lex和parse设想是通过flex, bison实现。  
但是主流的编译系统，这一部分都已经改为手写分析器的方式了。  
主要原因是，虽然理论上走的是lex->parse->ast这样的流程。  
但是实际的分析过程中，使用各种trick的地方特别多，比较难以通过这种生成代码的方式完整表达。  
另外，生成代码的方式可能会产生很多的空AST，影响程序的性能。  

以typedef的解析为例。

typedef语句的格式如下：  
```
"typedef" ${type} ${identifier} ";"

比如
typedef unsigned long FILE;
```

上述示例中，typedef将FILE声明成为了一个类型。那么下面的语句就应该可以编译。  
并且在实际生成IR时，去掉FILE这个声明，直接用unsigned long代替之。  
```
extern FILE* fopen(char* path, char* mode);
```

而在解析到这个extern语句时，就必须要知道FILE是一个类型，而不是一个标识符。
这就需要在解析到上面的typedef时，除了生成typedef的AST之外，  
还要记录FILE->unsigned long这样一个类型别名的映射，在解析到下面的extern时，将FILE当做类型解析，解析时查询类型别名的映射，才可以正常编译该语句。  

关于性能方面的问题，可以看下cbc中对操作符优先级的定义。  

```
$opassign_op -> "+=" / "-=" / "*=" / "/=" ...

$expr10 -> $expr9 ["?" $expr ":" $expr10]

$expr9 -> $expr8 ("||" $expr8)*

$expr8 -> $expr7 ("&&" $expr7)*

$expr7 -> $expr6 (">"/"<"/">="/"<="/"=="/"!=" $expr6)*

$expr6 -> $expr5 ("|" $expr5)*

$expr5 -> $expr4 ("^" $expr4)*

$expr4 -> $expr3 ("&" $expr3)*

$expr3 -> $expr2 (">>"/"<<" $expr2)*

$expr2 -> $expr1 ("+"/"-" $expr1)*

$expr1 -> $term ( "*" / "/" / "%" $term)*
```

感觉好啰嗦？C语言规范也是这么表达的。  
https://web.archive.org/web/20161223125339/http://flash-gordon.me.uk/ansi.c.txt  
(参考3.3.x章节，各个operator的表达式)  


LLVM的Kaleidoscope语言教程中，为操作符增加了额外的优先级信息，所以在解析时不需要这么一长串产生式了。  
但是这些优先级的设置、比较等等操作，就必须通过专门编写的代码才能实现了。  

总而言之，我们最终采用了手写解析器的实现方式。  

# Lex

## 新符号的表生成
编写lexer的过程中，尽管使用了手写实现，但是也可以有一些自动生成的部分。  
这里学习clang的实现方式，使用了表生成的技巧。    

把关键字，符号等记录在一个def文件中，根据需要在不同的方法中，为def文件中的定义使用不同的宏。
从而达到自动生成代码的目的。  

举例，我们在tokenkinds.def中，将关键字使用KEYWORD宏定义。
在枚举所有的token kind时，KEYWORD就是普通的值；在判断关键字的kind时，KEYWORD定义成一个if + return的表达式。

通过这种技巧，如果增加关键字的话，只要在.def中增加一个定义，相关的后续代码都可以自动生成。 

## 字符流

我们的文件中，一个源代码文件大小能到几百KB，已经很多了。cbc的源代码，较大的也只是几十KB。  
而这几十个KB中，实际存在的符号也可能只有几千个。如果不是一些自动生成的桩代码，单个编译单元几百KB/几千token的规模，已经可以写出很多实用程序了。  
而这个资源规模，对于一般的桌面个人用系统来讲，轻轻松松就可以承受。
所以，将所有的源代码文件，全部加载到内存中处理，所有的文本整个放在一个大的string对象中。
而不是采用一些随用随加载的buffer式的处理方式。  

这里有一个隐含的假设，就是读入的字符串中，不能出现'\0'。  
一般情况下，编译器的输入都是人工输入的文本文件，都能满足这种情况。  
不过如果是用一个二进制作为输入，或者模块作为库存在的话，输入一个动态的字符串，是可能违反这种情况的。  
如果是后者，在处理时，会直接将出现'\0'的情况当成非法输入拒绝掉，未来会对这个场景做检查。  

在解析token时，我们会记录这个token的位置，
token的位置包括文件/行/列，行与列指的是，该token对应的第一个字符所在的行和列。  

记录位置主要用于生成诊断信息。  

# Parse

## 语句和表达式

语句(Stmt)和表达式(Expr)是不一样的，最根本的区别在于，表达式会最终计算出一个值，而语句只是记录一个执行序列。  

所以，表达式在进行代码生成的时候，codegen的结果必须返回给上层表达式，用于取值。  
而语句在进行代码生成的时候，只要生成自身的执行序列即可。  
if, for, while, break, return这些语句，都不会产生一个具体的值被直接使用。  

在各个ast的codegen方法中，StmtAST的返回值只用于描述生成是否成功。但是返回值除了做!=nullptr的检查之外，不会被再做使用。  


## Parse的过程

执行了lex操作之后，输入的字符串会被转换成一个Token列表，  
在Parse的时候，就会从这个列表中不断地读取token。 

以下为cbc支持的整个产生式序列。  

```
1. $compilation_unit -> ($import_stmt)* ($top_def)*

2. $declaration_file -> $import_stmts ($funcdecl/$vardecl/$def_struct/$typedef)*``

3. $import_stmt -> "import" $name ("." $name)* ";"

4. $top_defs -> ($def_func/$def_var/$def_struct/$typedef)*

5. $def_func -> $storage $typeref $name "(" $params ")" $block

6. $storage -> "static" / ^

7. $params -> ^ / $param ("," $param)*

```


Parser的代码见parser.cc，parse本身的工作不难，
只要按照产生式文法的要求，从token列表中不断读取token，然后执行解析就可以了。  

举例：

while stmt的产生式如下：

```
$while_stmt -> "while" "(" $expr ")" $stmt
```

parser对应的代码如下，和上面的产生式对照，逻辑看起来也很容易理解。

1. 第一个符号是while，正确的话，消费掉该符号  
2. 第二个符号是(；正确的话，消费掉该符号  
3. 接下来是一个表达式expr，用于判断是否继续执行循环体  
4. 接下来的符号是)；正确的话，消费掉该符号  
5. 接下来是一个语句stmt。  

3和5中获取的expr和stmt，需要记录在WhileStmtAST中，用于后续的代码生成。

```
std::unique_ptr<WhileStmtAST> Parser::parseWhileStmtAST() {
    auto curTok = tokenCache_->cur();
    if (curTok.kind != tok::TokenKind::kw_while) {
        return nullptr;
    }
    tokenCache_->consume();
    curTok = tokenCache_->cur();
    if (curTok.kind != tok::TokenKind::l_paren) {
        return nullptr;
    }
    tokenCache_->consume();
    auto expr = parseExpression();
    if (expr == nullptr) {
        return nullptr;
    }
    curTok = tokenCache_->cur();
    if (curTok.kind != tok::TokenKind::r_paren) {
        return nullptr;
    }
    tokenCache_->consume();
    auto stmt = parseStmtBasicAST();
    if (stmt == nullptr) {
        return nullptr;
    }
    return std::make_unique<WhileStmtAST>(std::move(expr), std::move(stmt));
}
```



