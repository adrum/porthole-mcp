package dev.porthole.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** The Compose screen: a count, a field, a switch; testTags are the ids. */
class ComposeActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                var count by remember { mutableIntStateOf(0) }
                var name by remember { mutableStateOf("") }
                var dark by remember { mutableStateOf(false) }
                Column(Modifier.safeDrawingPadding().padding(24.dp)) {
                    Text("Count: $count", Modifier.testTag("count"))
                    Button(onClick = { count++ }, Modifier.testTag("add")) { Text("Add") }
                    TextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, modifier = Modifier.testTag("name"))
                    Text("Hello, ${name.ifEmpty { "nobody" }}", Modifier.testTag("greeting"))
                    Switch(checked = dark, onCheckedChange = { dark = it }, modifier = Modifier.testTag("dark"))
                }
            }
        }
    }
}
