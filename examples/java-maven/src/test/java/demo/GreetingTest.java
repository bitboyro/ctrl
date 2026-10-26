package demo;

public final class GreetingTest {
    public static void main(String[] args) {
        if (!App.greeting("Ada").equals("Hello, Ada!")) throw new AssertionError("Named greeting");
        if (!App.greeting("$(echo hello)").equals("Hello, $(echo hello)!")) throw new AssertionError("Literal input");
        System.out.println("2 greeting tests passed");
    }
}
