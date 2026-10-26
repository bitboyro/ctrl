# Java / Maven application

A small Java CLI application. It needs JDK 17+ for compilation, and Maven for the
package operation. ctrl does not detect Maven or implement a build-tool matrix;
these build details belong to the project's scripts and pom.xml.

Inspect without a JDK, Maven, downloads, or writes to application artifacts:

```bash
ctrl check
ctrl help build --source
ctrl test --dry-run
ctrl build --dry-run
```

With the prerequisites installed:

```bash
ctrl test --yes
ctrl build --yes
ctrl greet Ada
```

Test compiles and runs the greeting assertions with javac/java, using only the JDK.
It declares write effects because it creates `.local/test` class files. Build uses
Maven, skips tests explicitly, writes `.local/build/demo.jar`, and may download
plugins into the project-local `.local/m2` cache. It never pushes to a repository.
The test operation must be run separately; build does not imply test success.

Greet runs the built JAR with a validated token. A real project can replace these
scripts with its own Maven module selection, test framework, or publication policy.
Declare any credentials or nonstandard JAVA_HOME requirements explicitly rather
than assuming the agent's whole environment is inherited.
