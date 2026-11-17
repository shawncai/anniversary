package com.shiri.anniversary;

import android.app.Activity;
import android.app.Instrumentation;
import android.appwidget.AppWidgetHost;
import android.appwidget.AppWidgetHostView;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.os.Bundle;
import android.view.View;
import android.widget.TextView;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.util.List;
import java.util.Arrays;
import java.util.Map;

/** Test-APK-only native host: no component or fixture is added to the production APK. */
public final class WidgetRenderHarness extends Instrumentation {
    private static final int HOST_ID = 0x53485249;
    private Throwable failure;
    private final StringBuilder report = new StringBuilder();

    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            checkPlatformCrypto();
            runOnMainSync(() -> {
                try { renderWidgets(); } catch (Throwable error) { failure = error; }
            });
            if (failure != null) throw new AssertionError("Native widget check failed", failure);
            result.putString("stream", "\nPASS: actual AppWidgetHostView small/medium rendering and event selection\n" + report);
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "\nFAIL: " + error + "\n" + (failure == null ? "" : failure.toString()) + "\n");
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private void checkPlatformCrypto() {
        ShiriCrypto crypto = new ShiriCrypto();
        byte[] sealed = crypto.crypt(true, new byte[32], new byte[12], new byte[0], new byte[0]);
        StringBuilder hex = new StringBuilder();
        for (byte b : sealed) hex.append(String.format("%02x", b));
        if (!hex.toString().equals("530f8afbc74536b9a963b4f1c4cb738b")) throw new AssertionError("Android AES-GCM known-answer vector failed");
        sealed[0] ^= 1;
        try { crypto.crypt(false, new byte[32], new byte[12], sealed, new byte[0]); throw new AssertionError("Android accepted a tampered tag"); }
        catch (Exception expected) { if (!(expected instanceof javax.crypto.AEADBadTagException)) throw new AssertionError(expected); }
        Map<String, Object> a = crypto.keyPair(), b = crypto.keyPair();
        byte[] ak = crypto.derive((String) a.get("handle"), (byte[]) b.get("publicKey"), new byte[32]);
        byte[] bk = crypto.derive((String) b.get("handle"), (byte[]) a.get("publicKey"), new byte[32]);
        if (!Arrays.equals(ak, bk) || ak.length != 32) throw new AssertionError("Android P-256/HKDF agreement failed");
        report.append("Android native AES-GCM vector, tamper rejection, P-256/HKDF: PASS\n");
    }

    private void renderWidgets() throws Exception {
        Context context = getTargetContext();
        List<JSONObject> events = WidgetStore.INSTANCE.events(context);
        if (events.isEmpty()) throw new AssertionError("Import test user data into the app before rendering widgets");
        JSONObject event = events.get(events.size() - 1);
        for (JSONObject candidate : events) {
            if (new File(candidate.optString("coverPath")).isFile()) { event = candidate; break; }
        }
        AppWidgetManager manager = AppWidgetManager.getInstance(context);
        AppWidgetHost host = new AppWidgetHost(context, HOST_ID);
        int id = AppWidgetManager.INVALID_APPWIDGET_ID;
        try {
            host.startListening();
            id = host.allocateAppWidgetId();
            Bundle small = options(180, 180);
            if (!manager.bindAppWidgetIdIfAllowed(id, new ComponentName(context, ShiriWidgetProvider.class), small)) {
                throw new AssertionError("Grant bind only on the test emulator before running this instrumentation");
            }
            // This is exactly the per-widget preference written by the real configuration Activity.
            WidgetStore.INSTANCE.preferences(context).edit().putString(Integer.toString(id), event.getString("id")).commit();
            render(context, manager, host, id, event, 140, 140, "widget-compact.png");
            render(context, manager, host, id, event, 340, 140, "widget-compact-wide.png");
            render(context, manager, host, id, event, 180, 180, "widget-small.png");
            render(context, manager, host, id, event, 340, 180, "widget-medium.png");
            String chosen = WidgetStore.INSTANCE.preferences(context).getString(Integer.toString(id), null);
            if (!event.getString("id").equals(chosen)) throw new AssertionError("Widget event selection was lost on resize");
        } finally {
            if (id != AppWidgetManager.INVALID_APPWIDGET_ID) {
                host.deleteAppWidgetId(id);
                WidgetStore.INSTANCE.preferences(context).edit().remove(Integer.toString(id)).commit();
            }
            host.stopListening();
        }
    }

    private void render(Context context, AppWidgetManager manager, AppWidgetHost host, int id,
                        JSONObject event, int widthDp, int heightDp, String filename) throws Exception {
        manager.updateAppWidgetOptions(id, options(widthDp, heightDp));
        ShiriWidgetProvider.Companion.render(context, manager, id);
        AppWidgetProviderInfo info = manager.getAppWidgetInfo(id);
        if (info == null) throw new AssertionError("Bound widget provider is missing");
        AppWidgetHostView view = host.createView(context, id, info);
        float density = context.getResources().getDisplayMetrics().density;
        int width = Math.round(widthDp * density);
        int height = Math.round(heightDp * density);
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY));
        view.layout(0, 0, width, height);
        TextView title = view.findViewById(R.id.widget_title);
        TextView days = view.findViewById(R.id.widget_days);
        TextView elapsed = view.findViewById(R.id.widget_elapsed);
        if (title == null || days == null || elapsed == null) throw new AssertionError("RemoteViews did not inflate its real layout");
        if (!event.getString("title").equals(title.getText().toString())) throw new AssertionError("Wrong configured event title");
        if (days.getText().length() == 0 || !elapsed.getText().toString().startsWith("已走过")) throw new AssertionError("Widget did not populate calendar day counts");
        if (!title.getTypeface().equals(context.getResources().getFont(R.font.source_han_sans_cn_medium)) ||
            !days.getTypeface().equals(context.getResources().getFont(R.font.source_han_sans_cn_light)) ||
            !elapsed.getTypeface().equals(context.getResources().getFont(R.font.source_han_sans_cn_regular))) {
            throw new AssertionError("Native widget did not apply bundled Source Han Sans");
        }
        int daySpace = days.getHeight() - days.getCompoundPaddingTop() - days.getCompoundPaddingBottom();
        if (days.getLayout() == null || days.getLayout().getHeight() > daySpace) {
            throw new AssertionError("Countdown text is clipped by native font metrics");
        }
        report.append("Source Han Sans native TextView faces and visible countdown: PASS\n");
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try (FileOutputStream out = new FileOutputStream(new File(context.getCacheDir(), filename))) {
            view.draw(new Canvas(bitmap));
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) throw new AssertionError("Could not write widget render");
        } finally { bitmap.recycle(); }
        report.append(filename).append(": ").append(width).append('x').append(height)
            .append("; ").append(title.getText()).append("; ").append(days.getText()).append("; ").append(elapsed.getText()).append('\n');
    }

    private Bundle options(int width, int height) {
        Bundle options = new Bundle();
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, width);
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, width);
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, height);
        options.putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, height);
        return options;
    }
}
