package dev.porthole

import org.junit.Assert.assertEquals
import org.junit.Test

class TreeTest {
    private fun node(id: String) = Node(id, "row", null, null, emptyMap(), 0f, 0f, 1f, 1f, null)

    @Test
    fun repeatedIdsGetNumbered() {
        val root = node("w1")
        val list = node("list")
        root.children += list
        list.children += listOf(node("row"), node("row"), node("row"), node("other"))
        Tree.uniqueIds(root)
        assertEquals(listOf("row", "row@2", "row@3", "other"), list.children.map { it.id })
    }
}
