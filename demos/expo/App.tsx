import { useState } from 'react';
import { FlatList, LogBox, Modal, Pressable, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import { StatusBar } from 'expo-status-bar';

// Dev warnings toast over the list; keep the screen deterministic for tests.
LogBox.ignoreAllLogs();

const ITEMS = Array.from({ length: 50 }, (_, i) => i + 1);

export default function App() {
  const [email, setEmail] = useState('');
  const [changes, setChanges] = useState(0);
  const [notify, setNotify] = useState(false);
  const [status, setStatus] = useState('Not saved');
  const [picked, setPicked] = useState<number | null>(null);
  const [modal, setModal] = useState(false);

  return (
    <View style={styles.screen}>
      <Text style={styles.title} accessibilityRole="header">
        React Native Demo
      </Text>
      <TextInput
        testID="email"
        style={styles.input}
        placeholder="Email"
        autoCapitalize="none"
        value={email}
        onChangeText={(text) => {
          setEmail(text);
          setChanges((n) => n + 1);
        }}
        onSubmitEditing={() => setStatus(`Submitted ${email}`)}
      />
      <Text testID="changes">Changes: {changes}</Text>
      <View style={styles.row}>
        <Text>Notify me</Text>
        <Switch testID="notify" accessibilityLabel="Notify me" value={notify} onValueChange={setNotify} />
      </View>
      <View style={styles.row}>
        <Pressable testID="save" accessibilityRole="button" style={styles.button} onPress={() => setStatus(`Saved ${email}${notify ? ' (notify)' : ''}`)}>
          <Text style={styles.buttonText}>Save</Text>
        </Pressable>
        <Pressable testID="open-modal" style={styles.button} onPress={() => setModal(true)}>
          <Text style={styles.buttonText}>Open Modal</Text>
        </Pressable>
      </View>
      <Text testID="status">{status}</Text>
      <Text testID="picked">{picked === null ? 'Nothing picked' : `Picked ${picked}`}</Text>
      <FlatList
        testID="items"
        style={styles.list}
        data={ITEMS}
        keyExtractor={(n) => String(n)}
        renderItem={({ item }) => (
          <Pressable testID={`item-${item}`} accessibilityRole="button" style={styles.item} onPress={() => setPicked(item)}>
            <Text>Item {item}</Text>
          </Pressable>
        )}
      />
      <Modal visible={modal} animationType="slide" presentationStyle="pageSheet" onRequestClose={() => setModal(false)}>
        <View style={styles.modal}>
          <Text>A React Native modal</Text>
          <Pressable testID="close-modal" accessibilityRole="button" style={styles.button} onPress={() => setModal(false)}>
            <Text style={styles.buttonText}>Close</Text>
          </Pressable>
        </View>
      </Modal>
      <StatusBar style="dark" />
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, paddingTop: 70, paddingHorizontal: 20, gap: 10, backgroundColor: '#fff' },
  title: { fontSize: 22, fontWeight: '600' },
  input: { borderWidth: 1, borderColor: '#bbb', borderRadius: 8, padding: 10 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12 },
  button: { backgroundColor: '#2563eb', paddingVertical: 10, paddingHorizontal: 16, borderRadius: 8 },
  buttonText: { color: '#fff', fontWeight: '600' },
  list: { flex: 1 },
  item: { paddingVertical: 14, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: '#ccc' },
  modal: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 16 },
});
