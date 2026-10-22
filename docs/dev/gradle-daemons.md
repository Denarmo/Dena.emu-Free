# Gradle daemons on the dev PC

Many worktrees (`../Dena.emu-*`) build on one Windows PC. To keep them from each starting
a large daemon, `%USERPROFILE%\.gradle\gradle.properties` (which overrides the project's
`app/android/gradle.properties`) sets:

```
org.gradle.daemon.idletimeout=600000   # idle daemons exit after 10 minutes
org.gradle.workers.max=6
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=768m
kotlin.daemon.jvmargs=-Xmx1g
```

Because every worktree now uses the same JVM args and Gradle version, an idle daemon is
reused by whichever worktree builds next, so normally only one daemon is alive.
A second one appears only while two builds run at the same time.

Rules for threads:
- Run builds and tests once, when a thread's work is finished, not after every edit.
- Run `gradlew --stop` from `app/android` when no build is running to free all daemons.
