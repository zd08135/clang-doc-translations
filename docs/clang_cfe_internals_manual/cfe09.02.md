
# Type类和子类
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

# 公认类型
每个Type类都有一个公认类型指针。针对最简单的，不包含typedef的类型（比如int, int*, int\*\*等），这个指针就指向其自身。针对含有typedef信息的类型（比如上面例子的"foo","foo*","foo\*\*","bar"），公认类型指针指向的是与其结构一致的，不包含typedef信息的类型（比如，上面几个类型的指针各自指向：“int”, “int*”, “int**”, and “int*”）。  
这个设计可以使得访问类型信息时有常数的时间复杂度（只需解引用指针即可）。比如，我们可以很容易通过解引用+指针比较的方式，判定foo\*和bar为同一类型（都指向最普通的int\*类型)。  
公认类型也带来一些复杂性，需要小心处理。一般情况下，isa/cast/dyn_cast等操作符是不应该在检查AST的代码中出现的。比如，类型检查需要保证\*操作符的操作数，一定是指针类型。那么，这就没法正确地检查这样的表达式“isa<PointerType>(SubExpr->getType())"，因为如果SubExpr->getType()是一个typedef的类型，那么这个isa的推断就会出错。  
这个问题的解决方案是，在Type类中提供一个helper方法来检查其属性。本例中，使用SubExpr->getType()->isPointerType()来进行检查应该是正确的。如果其公认类型是一个指针，那么这个方法就会返回true，唯一需要注意的地方是不要使用isa/cast/dyn_cast这些操作符。  
第二个问题是，如何访问这个指针对应的类型。从上面的例子继续，\*操作的结果类型，必然是该表达式所指向的类型（比如，定义bar vx, \*vx的类型，就是foo，就是int）。为了找出这个类型，我们需要找到可以最佳捕获这个typedef信息的PointerType的实例。如果表达式本身的类型就是字面上的PointerType，那么就可以直接返回类型；否则我们必须沿着typedef信息挖下去。比如，若一个子表达式的类型是foo\*，那么我们就返回这个类型。如果类型是bar，我们希望返回的是foo\*（但是不是int\*）。为了达到这一目的，Type类提供了getAsPointerType()方法来检查类型本身是不是指针，如果是的话，就直接返回；否则会找一个最佳匹配的；如果不能匹配就返回空指针。  

> 这个结构有一点不是很清楚，需要好好的研究下才能明白。  