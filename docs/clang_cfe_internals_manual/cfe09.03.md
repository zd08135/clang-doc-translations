
# QualType类
QualType类是平凡的值类型，特点是小，一般通过值传递，且查找起来很高效。其思想为保存类型本身，以及类型限定符（比如const, volatile, restrict或者根据语言扩展的其他限定符）概念上，QualType包含由Type*指针和指明限定符的bit位组成的pair。  
用bit表示限定符，在增删改查方面效率都很高。  
将限定符的bit和类型分离保存的好处是，不需要针对不同的限定符也复制出不同的Type对象（比如，const int或者volatile int都只需要指向同一个int类型），这就减少了内存开销，在区分Type时也不需要考虑限定符信息。  
实现上，最常见的2个限定符（const和restrict）保存在指向Type的指针的最低位，还包含一位标识是否存在其他的限定符（新的部分要分配在堆上）。所以QualType的内存size和指针基本一致。  
> QualType在这里：clang/include/clang/AST/Type.h。
> ```c
> class QualType {
>   ...
>   // Thankfully, these are efficiently composable.
>   llvm::PointerIntPair<llvm::PointerUnion<const Type *, const ExtQuals *>,
>                      Qualifiers::FastWidth> Value;
>   ...
> };
> ```
> 其中，PointerIntPair这个类将一个指针和一个int合在一起存储，低位bit放int，高位放指针本身；在保证指针值完整保留的场景下可以这样来节省空间。     