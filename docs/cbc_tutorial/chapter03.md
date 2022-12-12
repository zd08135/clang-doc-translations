

# 编译

执行src目录下make即可。
```
make -C src
```

可以通过make -j 并行加速编译
```
make -C src -j 10
```
 
# 如何运行


cbc支持几种输出：


调试用：  

## 输出token
```
./src/cbc.bin test_codes/test2.bc -O 0 -emit-type ir -o test_codes/test2.bc.ll -import-root . -import-root ./imports -print-token
```

## 输出ast
```
```

## JIT计算
（这一块可以包装成一个库直接拿结果，不过目前只是运行输出结果）
```
root@e3277b26c17a:~/work/llvm_learn/cbc# ./src/cbc.bin test_codes/test3.bc -O 0-emit-type jit -import-root . -import-root ./imports                                                                               
jit eval result: 700

```

test3.bc的内容，可以自己验证下结果是否正确：
```
int func() {
    int[10][10] arr;
    int i,j,s;
    for (i = 0; i < 10; i = i + 1) {
        for (j = 0; j < 10; j = j + 1) {
            arr[i][j] = 5 + i + j;
        }
    }
    s = 0;
    for (i = 0; i < 10; i = i + 1) {
        for (j = 0; j < 10; j = j + 1) {
            s = s + arr[i][j];
        }
    }
    if (s > 0) {
        s = s / 2;
    }
    return s;
}

int main() {
    return func();
}

```

## 生成目标文件

hello world文件
```
import stdio;

int main(int argc, char** argv) {
    printf("hello world!\n");
    return 0;
}
```

编译生成的obj，需要再次链接一下才能生成elf文件。
gcc/clang都是这样做的。

```
root@e3277b26c17a:~/work/llvm_learn/cbc# ./src/cbc.bin test_codes/hello.bc -O 0 -emit-type obj -o test_codes/hello.bc.o -import-root . -import-root ./imports                                                      
output file: test_codes/hello.bc.o
root@e3277b26c17a:~/work/llvm_learn/cbc# clang test_codes/hello.bc.o -o test_codes/hello.bc.bin                                                                                                                    
root@e3277b26c17a:~/work/llvm_learn/cbc# ./test_codes/hello.bc.bin                                                                                                                                                 
hello world!
```
## 生成llvm-ir文件

llvm ir文件中生成的内容，会去掉一些只有编译前端用到的概念（比如语法糖等）  
也可以实现一些基本的优化，比如常量折叠等。  
可以用来查看变量、函数等声明信息“去伪存真”后的实际表示。

另一方面，在调试cbc的过程中，可以通过比较cbc输出的llvm ir与clang对同语义的C代码生成的llvm ir的内容，
来定位生成的错误。  

如下是上述hello world代码，对应的llvm ir表示。  

```
root@e3277b26c17a:~/work/llvm_learn/cbc# ./src/cbc.bin test_codes/hello.bc -O 0 -emit-type ir -o test_codes/hello.bc.o -import-root . -import-root ./imports                                                       
code:
; ModuleID = 'test_codes/hello.bc'
source_filename = "test_codes/hello.bc"

@0 = private unnamed_addr constant [14 x i8] c"hello world!\0A\00", align 1

declare i32 @printf(ptr, ...)

define dso_local i32 @main(i32 %argc, ptr %argv) {
entry:
  %argv2 = alloca ptr, align 8
  %argc1 = alloca i32, align 4
  store i32 %argc, ptr %argc1, align 4
  store ptr %argv, ptr %argv2, align 8
  %calltmp = call i32 (ptr, ...) @printf(ptr @0)
  ret i32 0
}
```

# 编程语言说明

本书实现的是《自制编译器》中选取的Cb语言，在该子集上又做了一些修改：
（实现的结果有点四不像，不过更接近一个实用的语言）

## 增加的部分  

- 支持浮点数
- 支持64位整数类型
- 支持变量的定义不一定在语句块头部
- 支持bool类型
- 支持nullptr关键字

## 去掉的部分  

- 不支持union联合类型。  

  主要原因是这个的实现太过于平台相关（依赖平台的内存布局），  
  比较难保证union的行为和平台的c编译器表现一致。  
  另外，因为数据重叠的缘故，union结构很破坏结构体内部的数据一致性。  
  union定义本身的作用也没那么大，设计初衷是自动的数据格式转换。一些出现较晚的编程语言都已经放弃了这个设定。  

- 不支持goto/label语句（未来可能支持）  
- 不支持switch/case语句（未来可能支持）  
- 不支持产生临时值的类型转换（赋值的是支持的，产生临时值的转换未来可能支持）  

```
int m = 12.345;  // 这样写可以编译
double d = 1.0 + m; // 这样写可以编译

double d = 1.0 + (int)12.345; // 这样写不能编译
```

- 去掉const  
  《自制编译器》中，针对const关键字，只支持了解析const本身；当然作者也提到了不支持const能力。
  const能力需要2部分支持：
1. 限制变量不可修改。  
   实现的方式是针对该变量的赋值操作做检查，这一部分实现比较容易。  
2. 完善的初始化列表。  
   主要是针对数组，因为数组需要支持初始化列表的嵌套，自动补齐等等。比如：
```
struct ST {
    int m;
    double d;
    char c;
};

const struct ST[3][3] csts = {{1, 1.0, 'c'}, ...};
```
   需要完成初始化列表的解析，"="左边和右边的检查，缺失部分补全等等。  
   实现代价比较大，所以这里就暂时没做。  

## 保持设定一致

- 导入其他文件符号的方式和Cb一致，用import语句。  
- 类型信息前置
```
// 多维数组定义
int[3][4] arr;

// 指针定义
int* pa, pb; // pa, pb类型都为int*

// 结构体数组
struct ST[10][10] sts; 
```