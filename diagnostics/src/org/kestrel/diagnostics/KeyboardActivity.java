package org.kestrel.diagnostics;

import android.app.Activity;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.inputmethod.InputMethodManager;
import android.content.Context;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import org.json.JSONObject;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** Dedicated test-only field. Reports comparisons, never captures entered text. */
public final class KeyboardActivity extends Activity {
    private EditText field;
    private static final String EXPECTED = "Kestrel keyboard 42";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(48, 64, 48, 48);
        TextView title = new TextView(this);
        title.setText("Kestrel keyboard diagnostic");
        title.setTextSize(24);
        layout.addView(title);
        field = new EditText(this);
        field.setSingleLine(true);
        field.setHint("Test field — no account data");
        field.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        field.setShowSoftInputOnFocus(false);
        layout.addView(field, new LinearLayout.LayoutParams(-1, 100));
        Button leave = new Button(this);
        leave.setText("Leave text field");
        leave.setFocusableInTouchMode(true);
        leave.setOnClickListener(view -> {
            field.clearFocus();
            leave.requestFocus();
            ((InputMethodManager)getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(field.getWindowToken(), 0);
            report();
        });
        layout.addView(leave);
        field.setOnFocusChangeListener((view, focused) -> report());
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            public void onTextChanged(CharSequence s, int start, int before, int count) { report(); }
            public void afterTextChanged(Editable text) {}
        });
        setContentView(layout);
        field.requestFocus();
        field.post(() -> report());
    }

    private void report() {
        try {
            JSONObject object = new JSONObject();
            object.put("focused", field.hasFocus());
            object.put("has_window_focus", hasWindowFocus());
            object.put("matches_expected", EXPECTED.contentEquals(field.getText()));
            object.put("matches_prefix", "Kestrel keyboard 4".contentEquals(field.getText()));
            object.put("matches_before_delete", "Kestrel keyboard 43".contentEquals(field.getText()));
            object.put("matches_expected_case_insensitive", EXPECTED.equalsIgnoreCase(field.getText().toString()));
            object.put("empty", field.length() == 0);
            object.put("length", field.length());
            try (FileOutputStream output = openFileOutput("keyboard-report.json", MODE_PRIVATE)) {
                output.write(object.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception error) { android.util.Log.e("KestrelKeyboard", "Could not write test result"); }
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (field != null) report();
    }
}
