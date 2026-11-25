package net.fledgewing.orbitcompanion;

/** Shared by the Gradle build and the app. Old releases used just the base (up to 0.11.3). */
public final class AndroidVersionCode {
    private AndroidVersionCode() {}
    public static final int OFFSET = 100_000_000;
    public static final int SCALE = 10_000;

    public static int encode(int major, int minor, int patch, String pre) {
        if (major < 0 || minor < 0 || minor >= 100 || patch < 0 || patch >= 100)
            throw new IllegalArgumentException("minor and patch must be below 100");
        int stage;
        if (pre == null) stage = 9999;
        else if (pre.equals("dev") || pre.startsWith("0.test.")) stage = 0;
        else {
            java.util.regex.Matcher m = java.util.regex.Pattern.compile("(preview|rc)\\.([1-9][0-9]*)").matcher(pre);
            if (!m.matches()) throw new IllegalArgumentException("use preview.N or rc.N (N: 1..3999)");
            int n = Integer.parseInt(m.group(2));
            if (n > 3999) throw new IllegalArgumentException("preview/rc number must be 1..3999");
            stage = n + (m.group(1).equals("rc") ? 4000 : 0);
        }
        long code = OFFSET + (major * 10_000L + minor * 100L + patch) * SCALE + stage;
        if (code > 2_100_000_000L) throw new IllegalArgumentException("version exceeds Android's versionCode limit");
        return (int) code;
    }
}
