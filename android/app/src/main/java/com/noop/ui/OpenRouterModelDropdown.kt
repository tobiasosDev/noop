package com.noop.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.ai.OpenRouterModel

/** The OpenRouter selector shared by setup and settings, with live prices and a searchable catalogue. */
@Composable
internal fun OpenRouterModelDropdown(
    models: List<String>,
    details: Map<String, OpenRouterModel>,
    selected: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    val option = details[selected] ?: OpenRouterModel(selected)
    TextButton(onClick = { query = ""; expanded = true }, modifier = Modifier.fillMaxWidth()) {
        Text(option.displayName, style = NoopType.body, color = Palette.textPrimary)
    }
    PriceCaption(option)
    if (!expanded) return
    val filtered = models.filter { id ->
        query.isBlank() || id.contains(query.trim(), ignoreCase = true)
            || (details[id] ?: OpenRouterModel(id)).displayName.contains(query.trim(), ignoreCase = true)
    }
    val budget = filtered.filter { it in OpenRouterModel.recommendedIDs }
    val other = filtered.filter { it !in OpenRouterModel.recommendedIDs }
    AlertDialog(
        onDismissRequest = { expanded = false },
        containerColor = Palette.surfaceOverlay,
        title = { Text(stringResource(R.string.openrouter_models), style = NoopType.headline, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
                OutlinedTextField(
                    value = query, onValueChange = { query = it }, singleLine = true,
                    label = { Text(stringResource(R.string.openrouter_search)) },
                    modifier = Modifier.fillMaxWidth(),
                )
                LazyColumn(modifier = Modifier.heightIn(max = Metrics.dialogScrollableMaxHeight)) {
                    fun androidx.compose.foundation.lazy.LazyListScope.modelGroup(title: Int, ids: List<String>) {
                        if (ids.isEmpty()) return
                        item {
                            Text(stringResource(title), style = NoopType.subhead, color = Palette.textSecondary,
                                modifier = Modifier.padding(vertical = Metrics.space12))
                        }
                        items(ids, key = { it }) { id ->
                            val model = details[id] ?: OpenRouterModel(id)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth().clickable { onSelect(id); expanded = false }
                                    .padding(vertical = Metrics.space8),
                            ) {
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                                    Text(model.displayName, style = NoopType.body, color = Palette.textPrimary)
                                    Text(id, style = NoopType.caption, color = Palette.textTertiary)
                                    PriceCaption(model)
                                }
                                RadioButton(selected = id == selected, onClick = { onSelect(id); expanded = false })
                            }
                        }
                    }
                    modelGroup(R.string.openrouter_budget_picks, budget)
                    modelGroup(R.string.openrouter_all_models, other)
                    val customID = query.trim()
                    if (customID.isNotEmpty() && customID !in models) {
                        item {
                            TextButton(onClick = { onSelect(customID); expanded = false }) {
                                Text(stringResource(R.string.openrouter_custom_model), color = Palette.accent)
                            }
                        }
                    }
                }
                Text(stringResource(R.string.openrouter_price_note), style = NoopType.caption, color = Palette.textTertiary)
            }
        },
        confirmButton = {
            TextButton(onClick = { expanded = false }) {
                Text(stringResource(android.R.string.cancel), color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun PriceCaption(model: OpenRouterModel) {
    val figures = model.priceFigures
    Text(
        if (figures == null) stringResource(R.string.openrouter_refresh_prices)
        else stringResource(R.string.openrouter_price, figures.first, figures.second),
        style = NoopType.caption, color = Palette.textSecondary,
    )
}
