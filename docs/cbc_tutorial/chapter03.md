

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


