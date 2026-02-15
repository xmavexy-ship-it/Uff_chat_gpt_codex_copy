package com.maweplayer

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PauseCircle
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            MaterialTheme {
                val tracks = remember { demoTracks }
                val player = remember {
                    ExoPlayer.Builder(this).build().apply {
                        setMediaItems(tracks.map { MediaItem.fromUri(it.url) })
                        prepare()
                    }
                }

                DisposableEffect(Unit) {
                    onDispose {
                        player.release()
                    }
                }

                MaweplayerScreen(player = player, tracks = tracks)
            }
        }
    }
}

@Composable
private fun MaweplayerScreen(player: ExoPlayer, tracks: List<Track>) {
    var currentTrackIndex by remember { mutableIntStateOf(0) }
    var isPlaying by remember { mutableStateOf(player.isPlaying) }
    var position by remember { mutableLongStateOf(0L) }
    var duration by remember { mutableLongStateOf(1L) }

    LaunchedEffect(player, currentTrackIndex) {
        while (true) {
            isPlaying = player.isPlaying
            position = player.currentPosition
            duration = if (player.duration > 0) player.duration else 1L
            if (player.currentMediaItemIndex >= 0) {
                currentTrackIndex = player.currentMediaItemIndex
            }
            delay(500)
        }
    }

    val pulseAnimation = rememberInfiniteTransition(label = "pulse")
    val pulse by pulseAnimation.animateFloat(
        initialValue = 0.85f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulseValue"
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF141E30),
                        Color(0xFF243B55),
                        Color(0xFF0B0F1A)
                    )
                )
            )
            .padding(horizontal = 20.dp, vertical = 16.dp)
    ) {
        Column {
            Text(
                text = "Maweplayer",
                style = MaterialTheme.typography.headlineLarge,
                color = Color.White,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = "Твой стильный Android MP3 плеер",
                color = Color(0xFFE3ECFF),
                fontSize = 14.sp,
                modifier = Modifier.padding(top = 4.dp, bottom = 18.dp)
            )

            val current = tracks[currentTrackIndex]
            Card(
                shape = RoundedCornerShape(24.dp),
                colors = CardDefaults.cardColors(
                    containerColor = Color(0xFF1A2540).copy(alpha = 0.95f)
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    Box(
                        modifier = Modifier
                            .size(92.dp)
                            .alpha(if (isPlaying) pulse else 1f)
                            .clip(CircleShape)
                            .background(Color(0xFF5F76F5)),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(text = "♫", color = Color.White, fontSize = 34.sp)
                    }

                    Spacer(modifier = Modifier.height(14.dp))
                    Text(current.title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Text(current.artist, color = Color(0xFFB8C9FF), fontSize = 14.sp)

                    Spacer(modifier = Modifier.height(12.dp))
                    Slider(
                        value = position.toFloat(),
                        onValueChange = { value ->
                            position = value.toLong()
                        },
                        onValueChangeFinished = {
                            player.seekTo(position)
                        },
                        valueRange = 0f..duration.toFloat()
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(formatMs(position), color = Color(0xFFB8C9FF), fontSize = 12.sp)
                        Text(formatMs(duration), color = Color(0xFFB8C9FF), fontSize = 12.sp)
                    }

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 6.dp),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.SkipPrevious,
                            contentDescription = "Previous",
                            tint = Color.White,
                            modifier = Modifier
                                .size(44.dp)
                                .clickable {
                                    val next = (currentTrackIndex - 1 + tracks.size) % tracks.size
                                    currentTrackIndex = next
                                    player.seekTo(next, 0)
                                    player.playWhenReady = true
                                }
                        )

                        Icon(
                            imageVector = if (isPlaying) Icons.Rounded.PauseCircle else Icons.Rounded.PlayCircle,
                            contentDescription = "Play pause",
                            tint = Color(0xFF7FA1FF),
                            modifier = Modifier
                                .size(72.dp)
                                .clickable {
                                    if (player.isPlaying) player.pause() else player.play()
                                    isPlaying = player.isPlaying
                                }
                        )

                        Icon(
                            imageVector = Icons.Rounded.SkipNext,
                            contentDescription = "Next",
                            tint = Color.White,
                            modifier = Modifier
                                .size(44.dp)
                                .clickable {
                                    val next = (currentTrackIndex + 1) % tracks.size
                                    currentTrackIndex = next
                                    player.seekTo(next, 0)
                                    player.playWhenReady = true
                                }
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "Плейлист",
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp,
                modifier = Modifier.padding(bottom = 8.dp)
            )

            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                itemsIndexed(tracks) { index, track ->
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                currentTrackIndex = index
                                player.seekTo(index, 0)
                                player.playWhenReady = true
                            },
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(
                            containerColor = if (index == currentTrackIndex) {
                                Color(0xFF4E64D8)
                            } else {
                                Color(0xFF1A2540)
                            }
                        )
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column {
                                Text(track.title, color = Color.White, fontWeight = FontWeight.Medium)
                                Text(track.artist, color = Color(0xFFD3DEFF), fontSize = 12.sp)
                            }
                            Text(track.length, color = Color(0xFFE3ECFF), fontSize = 12.sp)
                        }
                    }
                }
            }
        }
    }
}

private data class Track(
    val title: String,
    val artist: String,
    val length: String,
    val url: String
)

private val demoTracks = listOf(
    Track("Lights in Motion", "Mawe Studio", "2:13", "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"),
    Track("Night Pulse", "Mawe Studio", "2:48", "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3"),
    Track("Ocean Skies", "Mawe Studio", "3:05", "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3")
)

private fun formatMs(value: Long): String {
    val totalSeconds = value / 1000
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return "%d:%02d".format(minutes, seconds)
}
