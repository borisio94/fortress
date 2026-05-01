import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities/global_stats.dart';
import '../../domain/usecases/get_all_shops_stats_usecase.dart';

// ─── Events ───────────────────────────────────────────────────────────────────
abstract class HubEvent extends Equatable {
  @override List<Object?> get props => [];
}
class LoadHubStats extends HubEvent {
  final String period;
  LoadHubStats(this.period);
  @override List<Object> get props => [period];
}

// ─── States ───────────────────────────────────────────────────────────────────
abstract class HubState extends Equatable {
  @override List<Object?> get props => [];
}
class HubInitial extends HubState {}
class HubLoading extends HubState {}
class HubLoaded extends HubState {
  final GlobalStats stats;
  HubLoaded(this.stats);
  @override List<Object> get props => [stats];
}
class HubError extends HubState {
  final String message;
  HubError(this.message);
  @override List<Object> get props => [message];
}

// ─── Bloc ─────────────────────────────────────────────────────────────────────
class HubBloc extends Bloc<HubEvent, HubState> {
  final GetAllShopsStatsUseCase getStats;

  HubBloc(this.getStats) : super(HubInitial()) {
    on<LoadHubStats>(_onLoad);
  }

  Future<void> _onLoad(LoadHubStats event, Emitter<HubState> emit) async {
    emit(HubLoading());
    try {
      final stats = await getStats(event.period);
      emit(HubLoaded(stats));
    } catch (e) {
      emit(HubError(e.toString().replaceAll('Exception: ', '')));
    }
  }
}