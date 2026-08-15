package dev.sergeinaumov.mactician.glesprobe;

import android.app.Activity;
import android.content.Intent;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLES31;
import android.opengl.GLSurfaceView;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.Arrays;
import java.util.Locale;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

public final class StressActivity extends Activity implements GLSurfaceView.Renderer {
    private static final String TAG = "MacticianGLES";

    private GLSurfaceView surface;
    private String runId;
    private int rounds;
    private int updates;
    private int bufferBytes;
    private int syncEvery;
    private int barrierEvery;
    private int warmupRounds;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent intent = getIntent();
        runId = sanitizeRunId(intent.getStringExtra("run_id"));
        rounds = boundedExtra(intent, "rounds", 8, 2, 30);
        updates = boundedExtra(intent, "updates", 4000, 1, 100000);
        bufferBytes = boundedExtra(intent, "bytes", 16384, 256, 1048576);
        syncEvery = boundedExtra(intent, "sync_every", 120, 1, 100000);
        barrierEvery = boundedExtra(intent, "barrier_every", 64, 0, 100000);
        warmupRounds = boundedExtra(intent, "warmup_rounds", 7, 1, rounds - 1);

        surface = new GLSurfaceView(this);
        surface.setEGLContextClientVersion(3);
        surface.setPreserveEGLContextOnPause(false);
        surface.setRenderer(this);
        surface.setRenderMode(GLSurfaceView.RENDERMODE_WHEN_DIRTY);
        setContentView(surface);
    }

    private static int boundedExtra(Intent intent, String name, int fallback, int minimum, int maximum) {
        int value = intent.getIntExtra(name, fallback);
        if (value < minimum || value > maximum) {
            throw new IllegalArgumentException(name + " must be from " + minimum + " through " + maximum);
        }
        return value;
    }

    private static String sanitizeRunId(String value) {
        if (value == null || !value.matches("[A-Za-z0-9._-]{1,80}")) {
            throw new IllegalArgumentException("run_id is required and must be safe for JSON/logcat");
        }
        return value;
    }

    private static String jsonEscape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    @Override
    public void onSurfaceCreated(GL10 ignored, EGLConfig config) {
        String renderer = GLES20.glGetString(GLES20.GL_RENDERER);
        String version = GLES20.glGetString(GLES20.GL_VERSION);
        String maps = readProcessMaps();
        boolean guestAngleMapped = maps.contains("libGLESv2_angle.so");
        boolean gfxstreamEncoderMapped = maps.contains("libGLESv2_enc.so");
        boolean ranchuVulkanMapped = maps.contains("vulkan.ranchu.so");
        Log.i(TAG, String.format(Locale.US,
                "{\"kind\":\"attestation\",\"run_id\":\"%s\",\"renderer\":\"%s\",\"version\":\"%s\",\"guest_angle_mapped\":%s,\"gfxstream_gles_encoder_mapped\":%s,\"ranchu_vulkan_mapped\":%s}",
                jsonEscape(runId), jsonEscape(renderer), jsonEscape(version),
                guestAngleMapped, gfxstreamEncoderMapped, ranchuVulkanMapped));
        try {
            runStress();
        } catch (Throwable failure) {
            Log.e(TAG, String.format(Locale.US,
                    "{\"kind\":\"failure\",\"run_id\":\"%s\",\"message\":\"%s\"}",
                    jsonEscape(runId), jsonEscape(String.valueOf(failure))));
        } finally {
            runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    finishAndRemoveTask();
                }
            });
        }
    }

    private static String readProcessMaps() {
        StringBuilder result = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/self/maps"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                result.append(line).append('\n');
            }
            return result.toString();
        } catch (IOException failure) {
            throw new IllegalStateException("could not read /proc/self/maps", failure);
        }
    }

    private void runStress() {
        ByteBuffer data = ByteBuffer.allocateDirect(bufferBytes).order(ByteOrder.nativeOrder());
        for (int index = 0; index < bufferBytes; index++) {
            data.put(index, (byte) (index * 31 + 17));
        }

        int[] buffers = new int[1];
        GLES30.glGenBuffers(1, buffers, 0);
        if (buffers[0] == 0) {
            throw new IllegalStateException("glGenBuffers returned zero");
        }
        GLES30.glBindBuffer(GLES30.GL_UNIFORM_BUFFER, buffers[0]);
        GLES30.glBufferData(GLES30.GL_UNIFORM_BUFFER, bufferBytes, null, GLES30.GL_DYNAMIC_DRAW);
        int setupError = GLES20.glGetError();
        if (setupError != GLES20.GL_NO_ERROR) {
            throw new IllegalStateException(String.format(Locale.US, "GLES setup error 0x%x", setupError));
        }

        double[] measuredNS = new double[rounds - warmupRounds];
        double[] measuredThroughput = new double[rounds - warmupRounds];
        int glErrorRounds = 0;
        try {
            for (int round = 0; round < rounds; round++) {
                long startedNS = SystemClock.elapsedRealtimeNanos();
                for (int update = 1; update <= updates; update++) {
                    data.put(0, (byte) (round + update));
                    data.position(0);
                    GLES30.glBufferSubData(GLES30.GL_UNIFORM_BUFFER, 0, bufferBytes, data);
                    if (barrierEvery > 0 && update % barrierEvery == 0) {
                        GLES31.glMemoryBarrier(GLES31.GL_BUFFER_UPDATE_BARRIER_BIT);
                    }
                    if (update % syncEvery == 0) {
                        GLES20.glFinish();
                    }
                }
                GLES20.glFinish();
                long elapsedNS = SystemClock.elapsedRealtimeNanos() - startedNS;
                int glError = GLES20.glGetError();
                double nsPerUpdate = (double) elapsedNS / updates;
                double mibPerSecond = ((double) bufferBytes * updates / (1024.0 * 1024.0))
                        / (elapsedNS / 1_000_000_000.0);
                Log.i(TAG, String.format(Locale.US,
                        "{\"kind\":\"buffer_stress_round\",\"run_id\":\"%s\",\"round\":%d,\"warmup\":%s,\"updates\":%d,\"bytes\":%d,\"sync_every\":%d,\"barrier_every\":%d,\"elapsed_ns\":%d,\"ns_per_update\":%.3f,\"mib_per_second\":%.3f,\"gl_error\":%d}",
                        jsonEscape(runId), round, round < warmupRounds, updates, bufferBytes, syncEvery,
                        barrierEvery, elapsedNS, nsPerUpdate, mibPerSecond, glError));
                if (round >= warmupRounds) {
                    int measuredIndex = round - warmupRounds;
                    measuredNS[measuredIndex] = nsPerUpdate;
                    measuredThroughput[measuredIndex] = mibPerSecond;
                    if (glError != GLES20.GL_NO_ERROR) {
                        glErrorRounds++;
                    }
                }
            }
        } finally {
            GLES30.glDeleteBuffers(1, buffers, 0);
        }

        Arrays.sort(measuredNS);
        Arrays.sort(measuredThroughput);
        Log.i(TAG, String.format(Locale.US,
                "{\"kind\":\"buffer_stress_summary\",\"run_id\":\"%s\",\"measured_rounds\":%d,\"median_ns_per_update\":%.3f,\"p95_ns_per_update\":%.3f,\"median_mib_per_second\":%.3f,\"gl_error_rounds\":%d}",
                jsonEscape(runId), measuredNS.length, percentile(measuredNS, 0.5),
                percentile(measuredNS, 0.95), percentile(measuredThroughput, 0.5), glErrorRounds));
    }

    private static double percentile(double[] sorted, double fraction) {
        double position = (sorted.length - 1) * fraction;
        int lower = (int) Math.floor(position);
        int upper = (int) Math.ceil(position);
        if (lower == upper) {
            return sorted[lower];
        }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
    }

    @Override
    public void onSurfaceChanged(GL10 ignored, int width, int height) {
        GLES20.glViewport(0, 0, width, height);
    }

    @Override
    public void onDrawFrame(GL10 ignored) {
        GLES20.glClearColor(0.02f, 0.02f, 0.02f, 1.0f);
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
    }
}
