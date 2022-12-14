
# 不变性
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

# 忠实性
AST会提供初始源代码的一个忠实表达。尽量只会用AST内部的或者再次构建信息来进行Refactor。这就要求AST表达不能解语法糖，也不能因为更清楚的表达而对代码进行解wrap。  
例如，CXXForRangeStmt 直接表达成一个range方式的语句，也包含range和迭代器相关的声明。但是不包含解语法糖之后的for语句。  
一些AST节点（比如ParenExpr）只包含语法信息，另一些（比如ImplicitCasrExpr）只包含语义信息；但是绝大多数的节点都是同时包含语法和语义信息。继承就是用来表达语法不同（但是相关）而语义相同的节点。  
