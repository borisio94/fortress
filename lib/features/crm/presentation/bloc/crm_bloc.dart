import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities/client.dart';
import '../../../../core/database/app_database.dart';

// ─── Events ──────────────────────────────────────────────────────────────────
abstract class CrmEvent extends Equatable {
  @override List<Object?> get props => [];
}

class LoadClients extends CrmEvent {
  final String shopId;
  LoadClients(this.shopId);
  @override List<Object> get props => [shopId];
}

class RefreshClients extends CrmEvent {
  final String shopId;
  RefreshClients(this.shopId);
  @override List<Object> get props => [shopId];
}

class SearchClients extends CrmEvent {
  final String query;
  SearchClients(this.query);
  @override List<Object> get props => [query];
}

class FilterClients extends CrmEvent {
  final String filter; // 'Tous' | 'VIP' | 'Régulier' | 'Nouveau'
  FilterClients(this.filter);
  @override List<Object> get props => [filter];
}

class SaveClient extends CrmEvent {
  final Client client;
  SaveClient(this.client);
  @override List<Object> get props => [client];
}

class DeleteClient extends CrmEvent {
  final String clientId;
  final String shopId;
  DeleteClient(this.clientId, this.shopId);
  @override List<Object> get props => [clientId, shopId];
}

// ─── States ───────────────────────────────────────────────────────────────────
abstract class CrmState extends Equatable {
  @override List<Object?> get props => [];
}

class CrmInitial  extends CrmState {}
class CrmLoading  extends CrmState {}

class CrmLoaded extends CrmState {
  final List<Client> clients;   // liste complète
  final List<Client> filtered;  // après recherche/filtre
  final String filter;
  final String query;

  CrmLoaded({
    required this.clients,
    List<Client>? filtered,
    this.filter = 'Tous',
    this.query  = '',
  }) : filtered = filtered ?? clients;

  CrmLoaded copyWith({
    List<Client>? clients,
    List<Client>? filtered,
    String? filter,
    String? query,
  }) => CrmLoaded(
    clients:  clients  ?? this.clients,
    filtered: filtered ?? this.filtered,
    filter:   filter   ?? this.filter,
    query:    query    ?? this.query,
  );

  @override List<Object> get props => [clients, filtered, filter, query];
}

class CrmError extends CrmState {
  final String message;
  CrmError(this.message);
  @override List<Object> get props => [message];
}

class CrmSaved extends CrmState {}

// ─── Bloc ─────────────────────────────────────────────────────────────────────
class CrmBloc extends Bloc<CrmEvent, CrmState> {
  CrmBloc() : super(CrmInitial()) {
    on<LoadClients>(_onLoad);
    on<RefreshClients>(_onRefresh);
    on<SearchClients>(_onSearch);
    on<FilterClients>(_onFilter);
    on<SaveClient>(_onSave);
    on<DeleteClient>(_onDelete);
  }

  // Charge depuis Hive (immédiat) + sync Supabase background
  Future<void> _onLoad(LoadClients event, Emitter<CrmState> emit) async {
    emit(CrmLoading());
    final clients = AppDatabase.getClientsForShop(event.shopId);
    emit(CrmLoaded(clients: clients));
    // Sync silencieuse en arrière-plan
    AppDatabase.syncClients(event.shopId).then((_) {
      final updated = AppDatabase.getClientsForShop(event.shopId);
      if (!isClosed) add(RefreshClients(event.shopId));
    });
  }

  // Rafraîchir depuis Hive (après sync)
  Future<void> _onRefresh(RefreshClients event, Emitter<CrmState> emit) async {
    final clients = AppDatabase.getClientsForShop(event.shopId);
    if (state is CrmLoaded) {
      final s = state as CrmLoaded;
      emit(CrmLoaded(
        clients:  clients,
        filtered: _applyFilter(clients, s.filter, s.query),
        filter:   s.filter,
        query:    s.query,
      ));
    } else {
      emit(CrmLoaded(clients: clients));
    }
  }

  void _onSearch(SearchClients event, Emitter<CrmState> emit) {
    if (state is! CrmLoaded) return;
    final s = state as CrmLoaded;
    emit(s.copyWith(
      filtered: _applyFilter(s.clients, s.filter, event.query),
      query:    event.query,
    ));
  }

  void _onFilter(FilterClients event, Emitter<CrmState> emit) {
    if (state is! CrmLoaded) return;
    final s = state as CrmLoaded;
    emit(s.copyWith(
      filtered: _applyFilter(s.clients, event.filter, s.query),
      filter:   event.filter,
    ));
  }

  Future<void> _onSave(SaveClient event, Emitter<CrmState> emit) async {
    try {
      await AppDatabase.saveClient(event.client);
      emit(CrmSaved());
    } catch (e) {
      emit(CrmError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onDelete(DeleteClient event, Emitter<CrmState> emit) async {
    try {
      await AppDatabase.deleteClient(event.clientId, event.shopId);
      emit(CrmSaved());
    } catch (e) {
      emit(CrmError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  List<Client> _applyFilter(
      List<Client> clients, String filter, String query) {
    var list = query.isEmpty
        ? clients
        : clients.where((c) =>
            c.name.toLowerCase().contains(query.toLowerCase()) ||
            (c.phone ?? '').contains(query) ||
            (c.email ?? '').toLowerCase().contains(query.toLowerCase())
          ).toList();

    switch (filter) {
      case 'VIP'      : return list.where((c) => c.tag == ClientTag.vip).toList();
      case 'Régulier' : return list.where((c) => c.tag == ClientTag.regular).toList();
      case 'Nouveau'  : return list.where((c) => c.tag == ClientTag.new_).toList();
      default          : return list;
    }
  }
}
