package demo;

public final class App {
    public static String greeting(String name) { return "Hello, " + name + "!"; }
    public static void main(String[] args) {
        System.out.println(greeting(args.length == 0 ? "world" : args[0]));
    }
}
