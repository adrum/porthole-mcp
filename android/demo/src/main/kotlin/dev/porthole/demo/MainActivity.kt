package dev.porthole.demo

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.TextView

/** The Views screen: a field, a checkbox, Save, a status line. */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        val email = findViewById<EditText>(R.id.email)
        val subscribe = findViewById<CheckBox>(R.id.subscribe)
        val status = findViewById<TextView>(R.id.status)
        findViewById<Button>(R.id.save).setOnClickListener {
            DemoState.saved = email.text.toString()
            val sub = if (subscribe.isChecked) " (subscribed)" else ""
            status.text = "Saved ${email.text}$sub"
            Log.i("Demo", "save tapped: ${email.text}")
        }
        findViewById<Button>(R.id.open_compose).setOnClickListener {
            startActivity(Intent(this, ComposeActivity::class.java))
        }
        DemoState.listeners += {
            email.setText("")
            subscribe.isChecked = false
            status.text = "Not saved"
        }
    }
}
