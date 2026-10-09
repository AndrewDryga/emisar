import java.nio.file.Files;
import java.nio.file.Path;

public class PerfFixture {
    public static void main(String[] args) throws Exception {
        Files.writeString(Path.of("/tmp", args[0] + ".pid"),
                Long.toString(ProcessHandle.current().pid()) + "\n");
        while (true) {
            Thread.sleep(1000);
        }
    }
}
